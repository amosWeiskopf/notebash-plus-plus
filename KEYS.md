# Notebash++ keys

Generated from `lua/notebashpp/keybindings.lua` by `tools/gen_keys.sh`.

The keys are Notepad++ 8.5.3's defaults (its `Parameters.cpp` key tables and
the stock `shortcuts.xml`), plus the ComparePlus 1.1.0 defaults.

To give a command other keys, put its id in the `keys` table of your
`user.lua` (see `user.example.lua`), e.g. `keys = { line_delete = { '<C-l>' } }`.

## File

| Key | Command | Id |
| --- | --- | --- |
| Ctrl+N | New | `new` |
| Ctrl+O | Open... | `open` |
| Ctrl+R | Reload from Disk | `reload` |
| Ctrl+S | Save | `save` |
| Ctrl+Alt+S | Save As... | `save_as` |
| Ctrl+Shift+S | Save All | `save_all` |
| Ctrl+W | Close | `close` |
| Ctrl+Shift+W | Close All | `close_all` |
| Ctrl+P | Print... | `print` |
| Alt+F4 | Exit | `exit` |
| Ctrl+Shift+T | Restore Recent Closed File | `restore_closed` |

## Edit

| Key | Command | Id |
| --- | --- | --- |
| Ctrl+Z, Alt+Backspace | Undo | `undo` |
| Ctrl+Y, Ctrl+Shift+Z | Redo | `redo` |
| Ctrl+X, Shift+Del | Cut | `cut` |
| Ctrl+C, Ctrl+Ins | Copy | `copy` |
| Ctrl+V, Shift+Ins | Paste | `paste` |
| Ctrl+A | Select All | `select_all` |
| Ctrl+Shift+B | Begin/End Select | `begin_select` |
| Alt+Shift+B | Begin/End Select in Column Mode | `begin_select_col` |
| Ctrl+Alt+Up | Expand Selection | `expand_selection` |
| Ctrl+Alt+Down | Shrink Selection | `shrink_selection` |
| Ctrl+Shift+E | Multi-select All: Match Case Only | `multi_select_all_match_case` |
| Ctrl+E | Multi-select Next: Match Case Only | `multi_select_next_match_case` |
| Ctrl+Shift+U | UPPERCASE | `upper` |
| Ctrl+U | lowercase | `lower` |
| Alt+U | Proper Case | `proper` |
| Alt+Shift+U | Proper Case (blend) | `proper_blend` |
| Ctrl+Alt+U | Sentence case | `sentence` |
| Ctrl+Alt+Shift+U | Sentence case (blend) | `sentence_blend` |
| Ctrl+I | Split Lines | `split_lines` |
| Ctrl+J | Join Lines | `join_lines` |
| Ctrl+Shift+Up | Move Up Current Line | `line_up` |
| Ctrl+Shift+Down | Move Down Current Line | `line_down` |
| Ctrl+Alt+Enter | Insert Blank Line Above Current | `blank_above` |
| Ctrl+Alt+Shift+Enter | Insert Blank Line Below Current | `blank_below` |
| Ctrl+Q | Toggle Single Line Comment | `comment_toggle` |
| Ctrl+K | Single Line Comment | `comment` |
| Ctrl+Shift+K | Single Line Uncomment | `uncomment` |
| Ctrl+Shift+Q | Block Comment | `stream_comment` |
| Ctrl+Space | Function Completion | `autocomplete` |
| Ctrl+Enter | Word Completion | `autocomplete_word` |
| Ctrl+Alt+Space | Path Completion | `autocomplete_path` |
| Ctrl+Shift+Space | Function Parameters Hint | `calltip` |
| Alt+C | Column Editor... | `column_editor` |
| Ctrl+D | Duplicate Current Line | `duplicate` |
| Ctrl+L | Cut Current Line | `line_cut` |
| Ctrl+Shift+L | Delete Current Line | `line_delete` |
| Ctrl+Shift+X | Copy Current Line | `line_copy` |
| Ctrl+T | Transpose Current and Previous Lines | `transpose` |
| Ctrl+Alt+R | Text Direction RTL | `rtl` |
| Ctrl+Alt+L | Text Direction LTR | `ltr` |

## Search

| Key | Command | Id |
| --- | --- | --- |
| Ctrl+F | Find... | `find` |
| Ctrl+Shift+F | Find in Files... | `find_in_files` |
| F3 | Find Next | `find_next` |
| Shift+F3 | Find Previous | `find_prev` |
| Ctrl+F3 | Select and Find Next | `set_find_next` |
| Ctrl+Shift+F3 | Select and Find Previous | `set_find_prev` |
| Ctrl+Alt+F3 | Find (Volatile) Next | `volatile_next` |
| Ctrl+Alt+Shift+F3 | Find (Volatile) Previous | `volatile_prev` |
| Ctrl+H | Replace... | `replace` |
| Ctrl+Alt+I | Incremental Search | `incremental` |
| F7 | Search Results Window | `focus_results` |
| F4 | Next Search Result | `next_result` |
| Shift+F4 | Previous Search Result | `prev_result` |
| Ctrl+G | Go to... | `goto_line` |
| Ctrl+B | Go to Matching Brace | `goto_brace` |
| Ctrl+Alt+B | Select All In-between {} [] or () | `select_braces` |
| Ctrl+M | Mark... | `mark` |
| Ctrl+1 | Jump Down: Using 1st Style | `style_next1` |
| Ctrl+Shift+1 | Jump Up: Using 1st Style | `style_prev1` |
| Ctrl+2 | Jump Down: Using 2nd Style | `style_next2` |
| Ctrl+Shift+2 | Jump Up: Using 2nd Style | `style_prev2` |
| Ctrl+3 | Jump Down: Using 3rd Style | `style_next3` |
| Ctrl+Shift+3 | Jump Up: Using 3rd Style | `style_prev3` |
| Ctrl+4 | Jump Down: Using 4th Style | `style_next4` |
| Ctrl+Shift+4 | Jump Up: Using 4th Style | `style_prev4` |
| Ctrl+5 | Jump Down: Using 5th Style | `style_next5` |
| Ctrl+Shift+5 | Jump Up: Using 5th Style | `style_prev5` |
| Ctrl+0 | Jump Down: Find Mark Style | `style_next0` |
| Ctrl+Shift+0 | Jump Up: Find Mark Style | `style_prev0` |
| Ctrl+F2 | Toggle Bookmark | `bookmark_toggle` |
| F2 | Next Bookmark | `bookmark_next` |
| Shift+F2 | Previous Bookmark | `bookmark_prev` |

## View

| Key | Command | Id |
| --- | --- | --- |
| F11 | Toggle Full Screen Mode | `fullscreen` |
| F12 | Post-It | `postit` |
| Ctrl+Numpad 1 | 1st Tab | `tab1` |
| Ctrl+Numpad 2 | 2nd Tab | `tab2` |
| Ctrl+Numpad 3 | 3rd Tab | `tab3` |
| Ctrl+Numpad 4 | 4th Tab | `tab4` |
| Ctrl+Numpad 5 | 5th Tab | `tab5` |
| Ctrl+Numpad 6 | 6th Tab | `tab6` |
| Ctrl+Numpad 7 | 7th Tab | `tab7` |
| Ctrl+Numpad 8 | 8th Tab | `tab8` |
| Ctrl+Numpad 9 | 9th Tab | `tab9` |
| Ctrl+PgDn | Next Tab | `tab_next` |
| Ctrl+PgUp | Previous Tab | `tab_prev` |
| Ctrl+Shift+PgDn | Move Tab Forward | `tab_move_fwd` |
| Ctrl+Shift+PgUp | Move Tab Backward | `tab_move_back` |
| Ctrl+Tab | Switch to next document | `next_doc` |
| Ctrl+Shift+Tab | Switch to previous document | `prev_doc` |
| Alt+H | Hide Lines | `hide_lines` |
| F8 | Focus on Another View | `switch_view` |
| Alt+0 | Fold All | `fold_all` |
| Alt+Shift+0 | Unfold All | `unfold_all` |
| Ctrl+Alt+F | Fold Current Level | `fold_current` |
| Ctrl+Alt+Shift+F | Unfold Current Level | `unfold_current` |
| Alt+1 | Fold Level 1 | `fold1` |
| Alt+Shift+1 | Unfold Level 1 | `unfold1` |
| Alt+2 | Fold Level 2 | `fold2` |
| Alt+Shift+2 | Unfold Level 2 | `unfold2` |
| Alt+3 | Fold Level 3 | `fold3` |
| Alt+Shift+3 | Unfold Level 3 | `unfold3` |
| Alt+4 | Fold Level 4 | `fold4` |
| Alt+Shift+4 | Unfold Level 4 | `unfold4` |
| Alt+5 | Fold Level 5 | `fold5` |
| Alt+Shift+5 | Unfold Level 5 | `unfold5` |
| Alt+6 | Fold Level 6 | `fold6` |
| Alt+Shift+6 | Unfold Level 6 | `unfold6` |
| Alt+7 | Fold Level 7 | `fold7` |
| Alt+Shift+7 | Unfold Level 7 | `unfold7` |
| Alt+8 | Fold Level 8 | `fold8` |
| Alt+Shift+8 | Unfold Level 8 | `unfold8` |
| Ctrl+Numpad +, Ctrl+=, Ctrl++, Ctrl+Shift+=, Ctrl+Wheel Up | Zoom In | `zoom_in` |
| Ctrl+Numpad -, Ctrl+-, Ctrl+Wheel Down | Zoom Out | `zoom_out` |
| Ctrl+Numpad / | Restore Default Zoom | `zoom_restore` |

## Plugins

| Key | Command | Id |
| --- | --- | --- |
| Ctrl+Alt+Shift+J | Show JSON Tree | `json_tree` |
| Ctrl+Alt+Shift+B | Pretty Print XML | `xml_format` |
| Ctrl+Alt+Shift+L | Linearize XML | `xml_linearize` |
| Ctrl+Alt+Shift+M | Check XML Syntax | `xml_check` |
| Ctrl+Alt+Shift+H | View in HEX | `hex_view` |

## Macro

| Key | Command | Id |
| --- | --- | --- |
| Ctrl+Shift+R | Start Recording / Stop Recording | `macro_record` |
| Ctrl+Shift+P | Playback | `macro_play` |
| Alt+Shift+S | Trim Trailing Space and Save | `trim_save` |

## Run

| Key | Command | Id |
| --- | --- | --- |
| F5 | Run... | `run` |
| Alt+F1 | Get PHP help | `php_help` |
| Alt+F3 | Wikipedia Search | `wikipedia` |
| Alt+F6 | Open selected file path in new instance | `new_instance` |

## Plugins (ComparePlus)

| Key | Command | Id |
| --- | --- | --- |
| Ctrl+Alt+1 | Set as First to Compare | `cmp_first` |
| Ctrl+Alt+C | Compare | `cmp_compare` |
| Ctrl+Alt+N | Compare Selections | `cmp_selections` |
| Ctrl+Alt+Shift+C | Find Unique Lines | `cmp_unique` |
| Ctrl+Alt+Shift+N | Find Unique Lines in Selections | `cmp_unique_sel` |
| Ctrl+Alt+X | Clear Active Compare | `cmp_clear` |
| Ctrl+Alt+D | Diff since last Save | `cmp_last_save` |
| Ctrl+Alt+M | Compare file/selection to Clipboard | `cmp_clipboard` |
| Ctrl+Alt+V | SVN Diff | `cmp_svn` |
| Ctrl+Alt+G | Git Diff | `cmp_git` |
| Alt+PgUp | Previous | `cmp_prev` |
| Alt+PgDn | Next | `cmp_next` |
| Ctrl+Alt+PgUp | First | `cmp_first_diff` |
| Ctrl+Alt+PgDn | Last | `cmp_last_diff` |

## Plugins (Language Server)

| Key | Command | Id |
| --- | --- | --- |
| Ctrl+F12 | Go to Definition | `lsp_definition` |
| Shift+F12 | Find References | `lsp_references` |
| Alt+F12 | Show Documentation | `lsp_hover` |
| Shift+F6 | Rename Symbol... | `lsp_rename` |
| Alt+Shift+F | Format Document | `lsp_format` |
| F9 | Next Problem | `lsp_next_problem` |
| Shift+F9 | Previous Problem | `lsp_prev_problem` |
| Ctrl+F9 | Show Problem Details | `lsp_problem_details` |

## Help

| Key | Command | Id |
| --- | --- | --- |
| F1 | About Notebash++ | `about` |
| Shift+F1 | What does this key do? | `key_help` |

## Menus

| Key | Command | Id |
| --- | --- | --- |
| Alt+F | File menu | `menu_file` |
| Alt+E | Edit menu | `menu_edit` |
| Alt+S | Search menu | `menu_search` |
| Alt+V | View menu | `menu_view` |
| Alt+N | Encoding menu | `menu_encoding` |
| Alt+L | Language menu | `menu_language` |
| Alt+T | Settings menu | `menu_settings` |
| Alt+O | Tools menu | `menu_tools` |
| Alt+M | Macro menu | `menu_macro` |
| Alt+R | Run menu | `menu_run` |
| Alt+P | Plugins menu | `menu_plugins` |
| Alt+W | Window menu | `menu_window` |
| Alt+Shift+/ | Help menu | `menu_help` |
| F10 | Menu bar | `menu_bar` |

## Commands without a key

In the menus, and ready for a key in `user.lua`.

| Menu | Command | Id |
| --- | --- | --- |
| File | Save a Copy As... | `save_copy` |
| Edit | Multi-select All: Ignore Case & Whole Word | `multi_select_all_ignore_case_whole_word` |
| Edit | Multi-select Next: Ignore Case & Whole Word | `multi_select_next_ignore_case_whole_word` |
| Edit | Multi-select All: Match Whole Word Only | `multi_select_all_whole_word` |
| Edit | Multi-select Next: Match Whole Word Only | `multi_select_next_whole_word` |
| Edit | Multi-select All: Match Case & Whole Word | `multi_select_all_match_case_whole_word` |
| Edit | Multi-select Next: Match Case & Whole Word | `multi_select_next_match_case_whole_word` |
| Edit | Undo the Latest Added Multi-Select | `multi_select_undo` |
| Edit | Skip Current & Go to Next Multi-Select | `multi_select_skip` |
| Edit | Column Mode to Carets | `column_to_carets` |
| Edit | iNVERT cASE | `invert` |
| Edit | ranDOm CasE | `random` |
| Edit | Block Uncomment | `stream_uncomment` |
| Edit | Trim Trailing Space | `trim_trailing` |
| Edit | Trim Leading Space | `trim_leading` |
| Edit | Trim Leading and Trailing Space | `trim_both` |
| Edit | EOL to Space | `eol_to_space` |
| Edit | TAB to Space | `tab_to_space` |
| Edit | Space to TAB (All) | `space_to_tab_all` |
| Edit | Space to TAB (Leading) | `space_to_tab_leading` |
| Search | Clear all marks | `clear_marks` |
| Search | Using 1st Style | `style_all1` |
| Search | Using 1st Style | `style_one1` |
| Search | Clear 1st Style | `style_clear1` |
| Search | 1st Style | `style_copy1` |
| Search | Using 2nd Style | `style_all2` |
| Search | Using 2nd Style | `style_one2` |
| Search | Clear 2nd Style | `style_clear2` |
| Search | 2nd Style | `style_copy2` |
| Search | Using 3rd Style | `style_all3` |
| Search | Using 3rd Style | `style_one3` |
| Search | Clear 3rd Style | `style_clear3` |
| Search | 3rd Style | `style_copy3` |
| Search | Using 4th Style | `style_all4` |
| Search | Using 4th Style | `style_one4` |
| Search | Clear 4th Style | `style_clear4` |
| Search | 4th Style | `style_copy4` |
| Search | Using 5th Style | `style_all5` |
| Search | Using 5th Style | `style_one5` |
| Search | Clear 5th Style | `style_clear5` |
| Search | 5th Style | `style_copy5` |
| Search | Clear all Styles | `style_clear_all` |
| Search | All Styles | `style_copy_all` |
| Search | Clear All Bookmarks | `bookmark_clear` |
| Search | Cut Bookmarked Lines | `bookmark_cut` |
| Search | Copy Bookmarked Lines | `bookmark_copy` |
| Search | Paste to (Replace) Bookmarked Lines | `bookmark_paste` |
| Search | Remove Bookmarked Lines | `bookmark_remove` |
| Search | Remove Non-Bookmarked Lines | `bookmark_remove_unmarked` |
| Search | Inverse Bookmark | `bookmark_inverse` |
| View | Move to Other View | `move_view` |
| View | Clone to Other View | `clone_view` |
| Settings | Dark Mode | `dark_mode` |
| Plugins | Spell Check Document | `spell_check` |
| Plugins | Find Next Misspelling | `spell_next` |
| Plugins | Find Previous Misspelling | `spell_prev` |
| Plugins | Add Word to Dictionary | `spell_add` |
| Plugins | Format JSON | `json_format` |
| Plugins | Minify JSON | `json_minify` |
| Plugins | Check JSON | `json_check` |
| Plugins | Copy JSON Path | `json_copy_path` |
| Plugins | Align by Equals | `align_equals` |
| Plugins | Align by Colon | `align_colon` |
| Plugins | Align by Text... | `align_text` |
| Plugins | Open as Spreadsheet / View as Text | `sheet_toggle` |
| Plugins | First Row Is the Header | `sheet_header` |
| Plugins | Insert Row Above | `sheet_row_above` |
| Plugins | Insert Row Below | `sheet_row_below` |
| Plugins | Duplicate Rows | `sheet_row_duplicate` |
| Plugins | Delete Rows | `sheet_row_delete` |
| Plugins | Move Rows Up | `sheet_row_up` |
| Plugins | Move Rows Down | `sheet_row_down` |
| Plugins | Insert Column Left | `sheet_column_left` |
| Plugins | Insert Column Right | `sheet_column_right` |
| Plugins | Delete Columns | `sheet_column_delete` |
| Plugins | Widen Column | `sheet_column_wider` |
| Plugins | Narrow Column | `sheet_column_narrower` |
| Plugins | Go to Row... | `sheet_go_to_row` |
| Plugins | Edit Cell | `sheet_edit_cell` |
| Plugins | Load Whole File for Editing | `large_file_load` |
| View | Word wrap | `word_wrap` |
| View | Show All Characters | `show_all_chars` |
| Macro | Save Current Recorded Macro... | `macro_save` |
| Macro | Run a Macro Multiple Times... | `macro_many` |
| Plugins (Language Server) | Language Server Status | `lsp_status` |
| Plugins (Language Server) | Look for Language Servers Again | `lsp_look_again` |
| Help | Message Log | `message_log` |

## Typing and moving the caret (Scintilla keys)

| Key | Does |
| --- | --- |
| Arrows, Home, End, PgUp, PgDn | Move the caret. Up and Down move by screen line and keep the column. |
| Home | With word wrap, first the start of the screen row; then the first non-blank; then column 1 |
| End | With word wrap, first the end of the screen row; pressed again, the end of the line |
| Shift + any of those | Select. Typing replaces the selection. |
| Ctrl+Left, Ctrl+Right | Previous / next word |
| Ctrl+Shift+Left, Ctrl+Shift+Right | Select to the previous word start / next word end |
| Ctrl+Home, Ctrl+End (+Shift) | Start / end of the document (select) |
| Alt+Home, Alt+End | Start / end of the screen line |
| Ctrl+[, Ctrl+] (+Shift) | Previous / next paragraph (select) |
| Ctrl+/, Ctrl+\ (+Shift) | Previous / next word part (select) |
| Ctrl+Up, Ctrl+Down | Scroll one line |
| Alt+Shift+arrows, Alt+Shift+Home/End/PgUp/PgDn, Alt+drag | Column (rectangular) selection; typing, Backspace, Delete, Tab, Cut, Copy, Paste then work on every line |
| Ctrl+click, Ctrl+drag, Ctrl+double-click | Add a caret (Ctrl+click a caret to remove it), a selection, a word: multi-editing. Typing, Backspace, Delete, Enter, Tab, Cut, Copy, Paste and the caret keys then work at every caret; Esc or a plain click goes back to one |
| Tab, Shift+Tab | Tab; with several lines selected, indent / outdent |
| Backspace, Shift+Backspace, Del | Delete |
| Ctrl+Backspace, Ctrl+Del | Delete to the word start / next word |
| Ctrl+Shift+Backspace, Ctrl+Shift+Del | Delete to the line start / end |
| Enter, Shift+Enter | New line (Enter or Tab takes the highlighted word in the completion list) |
| Insert | Overtype on / off |
| Esc | Close the completion list, the column selection or the extra carets; cancel a selection |
| Double-click | Select the word |
| Right-click | Context menu |
| Ctrl+mouse wheel | Zoom |

## Inside the Find / Replace / Find in Files / Mark dialog

| Key | Does |
| --- | --- |
| Enter | Find Next (Find, Replace), Find All (Find in Files), Mark All (Mark) |
| Shift+Enter | Find in the other direction |
| Tab, Shift+Tab | Next / previous field |
| Up, Down | Search history (imported from Notepad++'s config.xml when there is one) |
| Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+PgDn, Ctrl+PgUp | Next / previous tab of the dialog |
| Ctrl+F, Ctrl+H, Ctrl+Shift+F, Ctrl+M | Go to the Find, Replace, Find in Files, Mark tab |
| Alt+W | Match whole word only |
| Alt+C | Match case |
| Alt+P | Wrap around |
| Alt+N, Alt+X, Alt+G | Search mode: Normal, Extended, Regular expression |
| Alt+. | . matches newline |
| Alt+I | In selection |
| Alt+T | Count |
| Alt+R | Replace (Replace tab), Replace in Files (Find in Files tab) |
| Alt+A | Replace All |
| Alt+O | Find All / Replace All in All Opened Documents |
| Alt+F, Alt+L, Alt+E, Alt+S | Go to Find what, Replace with, Directory, Filters |
| Alt+B, Alt+H | In all sub-folders, In hidden folders |
| Alt+M | Bookmark line (Mark tab) |
| F3, Shift+F3 | Find Next / Previous |
| Esc | Close; the found text stays selected |

Added because the Notepad++ buttons have no letter: Alt+D Find All in Current
Document, Alt+K Backward direction, Alt+U Purge for each search, Alt+L Clear
all marks (Mark tab), Alt+Y Copy Marked Text.

## Inside the JSON tree panel

Plugins > JSON > Show JSON Tree (Ctrl+Alt+Shift+J) opens it on the right.

| Key | Does |
| --- | --- |
| Enter, click | Put the caret on that key or value in the document |
| Space, click on + or - | Open or close the object or array |
| Right | Open; if already open, go to its first item |
| Left | Close; if already closed, go to the parent |
| +, - | Open, close |
| Up, Down, PgUp, PgDn, Home, End | Move in the tree; the path above it follows |
| Ctrl+C | Copy the JSON path of the selected node |
| Esc, Ctrl+W, Ctrl+Alt+Shift+J | Close the panel |

## Using the menus

Alt+F File, Alt+E Edit, Alt+S Search, Alt+V View, Alt+N Encoding, Alt+L
Language, Alt+T Settings, Alt+O Tools, Alt+M Macro, Alt+R Run, Alt+P Plugins,
Alt+W Window, Alt+? Help, F10 the menu bar. Inside a menu: arrows, Enter, Esc
and the underlined letters. The menu bar at the top also takes mouse clicks.
