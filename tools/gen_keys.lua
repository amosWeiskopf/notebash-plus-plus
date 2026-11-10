-- writes keys.md from the key table. run it through tools/gen_keys.sh. i want
-- the documentation to stay true without anyone remembering. apparently
-- that's too much to ask of me, so here's a damn script.

local keybindings = require('notebashpp.keybindings')
local project_root = require('notebashpp').root

local output_lines = {
    '# Notebash++ keys',
    '',
    'Generated from `lua/notebashpp/keybindings.lua` by `tools/gen_keys.sh`.',
    '',
    "The keys are Notepad++ 8.5.3's defaults (its `Parameters.cpp` key tables and",
    'the stock `shortcuts.xml`), plus the ComparePlus 1.1.0 defaults.',
    '',
    'To give a command other keys, put its id in the `keys` table of your',
    "`user.lua` (see `user.example.lua`), e.g. `keys = { line_delete = { '<C-l>' } }`.",
    '',
}

local commands_by_section, section_order = {}, {}
for _, spec in ipairs(keybindings.list) do
    if #spec.keys > 0 and not spec.from_user then
        if not commands_by_section[spec.section] then
            commands_by_section[spec.section] = {}
            section_order[#section_order + 1] = spec.section
        end
        table.insert(commands_by_section[spec.section], spec)
    end
end

for _, section_name in ipairs(section_order) do
    output_lines[#output_lines + 1] = '## ' .. section_name
    output_lines[#output_lines + 1] = ''
    output_lines[#output_lines + 1] = '| Key | Command | Id |'
    output_lines[#output_lines + 1] = '| --- | --- | --- |'
    for _, spec in ipairs(commands_by_section[section_name]) do
        -- two spellings can print the same key: alt with an uppercase s, and
        -- alt+shift with a lowercase s, both print as alt+shift+s. each
        -- printed name goes in once. i already wasted my life configuring the
        -- damn editor; can we please avoid billing the reader twice?
        local already_listed, printed_keys = {}, {}
        for _, key in ipairs(spec.keys) do
            local printed_key = keybindings.pretty(key)
            if not already_listed[printed_key] then
                already_listed[printed_key] = true
                printed_keys[#printed_keys + 1] = printed_key
            end
        end
        local label = spec.label:gsub('|', '\\|')
        output_lines[#output_lines + 1] = ('| %s | %s | `%s` |'):format(table.concat(printed_keys, ', '), label, spec.id)
    end
    output_lines[#output_lines + 1] = ''
end

-- commands with no key still have ids; user.lua can assign them a key.
-- basically even an unused command has potential. i'm absolutely jealous.
output_lines[#output_lines + 1] = '## Commands without a key'
output_lines[#output_lines + 1] = ''
output_lines[#output_lines + 1] = 'In the menus, and ready for a key in `user.lua`.'
output_lines[#output_lines + 1] = ''
output_lines[#output_lines + 1] = '| Menu | Command | Id |'
output_lines[#output_lines + 1] = '| --- | --- | --- |'
for _, spec in ipairs(keybindings.list) do
    if #spec.keys == 0 and not spec.from_user then
        output_lines[#output_lines + 1] = ('| %s | %s | `%s` |'):format(spec.section, (spec.label:gsub('|', '\\|')), spec.id)
    end
end
output_lines[#output_lines + 1] = ''

vim.list_extend(output_lines, {
    '## Typing and moving the caret (Scintilla keys)',
    '',
    '| Key | Does |',
    '| --- | --- |',
    '| Arrows, Home, End, PgUp, PgDn | Move the caret. Up and Down move by screen line and keep the column. |',
    '| Home | With word wrap, first the start of the screen row; then the first non-blank; then column 1 |',
    '| End | With word wrap, first the end of the screen row; pressed again, the end of the line |',
    '| Shift + any of those | Select. Typing replaces the selection. |',
    '| Ctrl+Left, Ctrl+Right | Previous / next word |',
    '| Ctrl+Shift+Left, Ctrl+Shift+Right | Select to the previous word start / next word end |',
    '| Ctrl+Home, Ctrl+End (+Shift) | Start / end of the document (select) |',
    '| Alt+Home, Alt+End | Start / end of the screen line |',
    '| Ctrl+[, Ctrl+] (+Shift) | Previous / next paragraph (select) |',
    '| Ctrl+/, Ctrl+\\ (+Shift) | Previous / next word part (select) |',
    '| Ctrl+Up, Ctrl+Down | Scroll one line |',
    '| Alt+Shift+arrows, Alt+Shift+Home/End/PgUp/PgDn, Alt+drag | Column (rectangular) selection; typing, Backspace, Delete, Tab, Cut, Copy, Paste then work on every line |',
    '| Ctrl+click, Ctrl+drag, Ctrl+double-click | Add a caret (Ctrl+click a caret to remove it), a selection, a word: multi-editing. Typing, Backspace, Delete, Enter, Tab, Cut, Copy, Paste and the caret keys then work at every caret; Esc or a plain click goes back to one |',
    '| Tab, Shift+Tab | Tab; with several lines selected, indent / outdent |',
    '| Backspace, Shift+Backspace, Del | Delete |',
    '| Ctrl+Backspace, Ctrl+Del | Delete to the word start / next word |',
    '| Ctrl+Shift+Backspace, Ctrl+Shift+Del | Delete to the line start / end |',
    '| Enter, Shift+Enter | New line (Enter or Tab takes the highlighted word in the completion list) |',
    '| Insert | Overtype on / off |',
    '| Esc | Close the completion list, the column selection or the extra carets; cancel a selection |',
    '| Double-click | Select the word |',
    '| Right-click | Context menu |',
    '| Ctrl+mouse wheel | Zoom |',
    '',
    '## Inside the Find / Replace / Find in Files / Mark dialog',
    '',
    '| Key | Does |',
    '| --- | --- |',
    '| Enter | Find Next (Find, Replace), Find All (Find in Files), Mark All (Mark) |',
    '| Shift+Enter | Find in the other direction |',
    '| Tab, Shift+Tab | Next / previous field |',
    "| Up, Down | Search history (imported from Notepad++'s config.xml when there is one) |",
    '| Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+PgDn, Ctrl+PgUp | Next / previous tab of the dialog |',
    '| Ctrl+F, Ctrl+H, Ctrl+Shift+F, Ctrl+M | Go to the Find, Replace, Find in Files, Mark tab |',
    '| Alt+W | Match whole word only |',
    '| Alt+C | Match case |',
    '| Alt+P | Wrap around |',
    '| Alt+N, Alt+X, Alt+G | Search mode: Normal, Extended, Regular expression |',
    '| Alt+. | . matches newline |',
    '| Alt+I | In selection |',
    '| Alt+T | Count |',
    '| Alt+R | Replace (Replace tab), Replace in Files (Find in Files tab) |',
    '| Alt+A | Replace All |',
    '| Alt+O | Find All / Replace All in All Opened Documents |',
    '| Alt+F, Alt+L, Alt+E, Alt+S | Go to Find what, Replace with, Directory, Filters |',
    '| Alt+B, Alt+H | In all sub-folders, In hidden folders |',
    '| Alt+M | Bookmark line (Mark tab) |',
    '| F3, Shift+F3 | Find Next / Previous |',
    '| Esc | Close; the found text stays selected |',
    '',
    'Added because the Notepad++ buttons have no letter: Alt+D Find All in Current',
    'Document, Alt+K Backward direction, Alt+U Purge for each search, Alt+L Clear',
    'all marks (Mark tab), Alt+Y Copy Marked Text.',
    '',
    '## Inside the JSON tree panel',
    '',
    'Plugins > JSON > Show JSON Tree (Ctrl+Alt+Shift+J) opens it on the right.',
    '',
    '| Key | Does |',
    '| --- | --- |',
    '| Enter, click | Put the caret on that key or value in the document |',
    '| Space, click on + or - | Open or close the object or array |',
    '| Right | Open; if already open, go to its first item |',
    '| Left | Close; if already closed, go to the parent |',
    '| +, - | Open, close |',
    '| Up, Down, PgUp, PgDn, Home, End | Move in the tree; the path above it follows |',
    '| Ctrl+C | Copy the JSON path of the selected node |',
    '| Esc, Ctrl+W, Ctrl+Alt+Shift+J | Close the panel |',
    '',
    '## Using the menus',
    '',
    'Alt+F File, Alt+E Edit, Alt+S Search, Alt+V View, Alt+N Encoding, Alt+L',
    'Language, Alt+T Settings, Alt+O Tools, Alt+M Macro, Alt+R Run, Alt+P Plugins,',
    'Alt+W Window, Alt+? Help, F10 the menu bar. Inside a menu: arrows, Enter, Esc',
    'and the underlined letters. The menu bar at the top also takes mouse clicks.',
})

vim.fn.writefile(output_lines, project_root .. '/KEYS.md')
print('wrote KEYS.md')
