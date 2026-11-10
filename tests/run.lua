-- the whole test run. start it with: nvim -l tests/run.lua about a minute of
-- a robot typing into an invisible editor. i want a number to tell me i'm not
-- a failure. apparently this is my life now.
package.path = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h') .. '/?.lua;' .. package.path
local harness = require('harness')
local expect_equal, test_case = harness.expect_equal, harness.test_case

harness.start_editor()

-- reset each test: column mode & multi-editing off, back in insert mode,
-- fresh buffer lines & caret parked. basically everything gets another chance
-- except the bastard writing this.
local function start_with_lines(lines, line_number, column)
    harness.run_lua('require("notebashpp.column_mode").clear()')
    harness.run_lua('require("notebashpp.multi_editing").clear()')
    harness.press_keys('<Esc>')
    harness.set_buffer_lines(lines)
    harness.run_lua('vim.cmd("startinsert")')
    harness.wait_until_idle()
    harness.set_cursor_position(line_number or 1, column or 0)
end

io.write('typing and modes\n')
test_case('starts in insert mode with line numbers', function()
    expect_equal('i', harness.current_mode(), 'mode')
    expect_equal(true, harness.run_lua('return vim.wo.number'), 'number')
end)
test_case('typing inserts text', function()
    start_with_lines({ '' })
    harness.type_text('hello world')
    expect_equal('hello world', harness.buffer_text())
end)
test_case('Esc does not leave typing', function()
    start_with_lines({ 'abc' }, 1, 1)
    harness.press_keys('<Esc>')
    expect_equal('i', harness.current_mode())
    harness.type_text('X')
    expect_equal('aXbc', harness.buffer_text())
end)
test_case('Ctrl+Z undoes the typing run, Ctrl+Y redoes', function()
    start_with_lines({ '' })
    harness.type_text('one')
    harness.press_keys('<Left>')
    harness.type_text('X')
    harness.press_keys('<C-z>')
    expect_equal('one', harness.buffer_text())
    expect_equal({ 1, 2 }, harness.cursor_position(), 'caret where the text was')
    harness.press_keys('<C-y>')
    expect_equal('onXe', harness.buffer_text())
    expect_equal({ 1, 3 }, harness.cursor_position(), 'caret after the text')
    harness.press_keys('<C-z>')
    harness.press_keys('<C-z>')
    expect_equal('', harness.buffer_text())
    harness.press_keys('<C-S-z>')
    expect_equal('one', harness.buffer_text(), 'Ctrl+Shift+Z redoes')
end)
test_case('Ctrl+Z and Ctrl+Y with a selection, and after line commands', function()
    start_with_lines({ 'one', 'two' }, 1, 0)
    harness.run_lua('vim.bo.filetype = "lua"')
    harness.press_keys('<C-d>')
    harness.press_keys('<C-k>')
    expect_equal('-- one\none\ntwo', harness.buffer_text())
    harness.press_keys('<S-End>')
    harness.press_keys('<C-z>')
    expect_equal('one\none\ntwo', harness.buffer_text())
    expect_equal('i', harness.current_mode())
    harness.press_keys('<C-z>')
    expect_equal('one\ntwo', harness.buffer_text())
    harness.press_keys('<C-y>')
    harness.press_keys('<C-y>')
    expect_equal('-- one\none\ntwo', harness.buffer_text())
    harness.run_lua('vim.bo.filetype = ""')
end)

io.write('caret movement\n')
test_case('Home is smart home', function()
    start_with_lines({ '    text' }, 1, 6)
    harness.press_keys('<Home>')
    expect_equal({ 1, 4 }, harness.cursor_position())
    harness.press_keys('<Home>')
    expect_equal({ 1, 0 }, harness.cursor_position())
    harness.press_keys('<End>')
    expect_equal({ 1, 8 }, harness.cursor_position())
end)
test_case('End with word wrap: end of the screen row, then of the line', function()
    local words = {}
    for word_number = 1, 40 do
        words[word_number] = 'word' .. word_number
    end
    local text = table.concat(words, ' ')
    start_with_lines({ text, 'next' }, 1, 0)
    harness.run_lua('vim.wo.wrap = true')
    local screen_row_end_column = harness.run_lua([[
        local first_row = vim.fn.screenpos(0, 1, 1).row
        for column = 1, #vim.api.nvim_get_current_line() do
            if vim.fn.screenpos(0, 1, column).row ~= first_row then return column - 1 end
        end
    ]])
    expect_equal(true, screen_row_end_column > 10 and screen_row_end_column < #text, 'line wraps')
    harness.press_keys('<End>')
    expect_equal({ 1, screen_row_end_column }, harness.cursor_position(), 'first End')
    harness.press_keys('<End>')
    expect_equal({ 1, #text }, harness.cursor_position(), 'second End')
    harness.press_keys('<Home>')
    local last_screen_row_start_column = harness.run_lua([[
        local last_row = vim.fn.screenpos(0, 1, #vim.api.nvim_get_current_line()).row
        for column = 1, #vim.api.nvim_get_current_line() do
            if vim.fn.screenpos(0, 1, column).row == last_row then return column - 1 end
        end
    ]])
    expect_equal({ 1, last_screen_row_start_column }, harness.cursor_position(), 'Home to the start of the screen row')
    harness.press_keys('<Home>')
    expect_equal({ 1, 0 }, harness.cursor_position(), 'Home again to the line start')
    harness.set_cursor_position(1, 0)
    harness.press_keys('<S-End>')
    expect_equal(text:sub(1, screen_row_end_column), harness.selected_text(), 'Shift+End selects to the row end')
    harness.press_keys('<S-End>')
    expect_equal(text, harness.selected_text(), 'Shift+End again selects to the line end')
    harness.press_keys('<S-Home>')
    expect_equal(text:sub(1, last_screen_row_start_column), harness.selected_text(), 'Shift+Home to the start of the screen row')
    harness.press_keys('<S-Home>')
    expect_equal('', harness.selected_text(), 'Shift+Home again back to the anchor')
    harness.press_keys('<Right>')
end)
test_case('Ctrl+Shift+End / Ctrl+Shift+Home select to the document ends', function()
    start_with_lines({ 'one', 'two', 'three' }, 2, 1)
    harness.press_keys('<C-S-End>')
    expect_equal('wo\nthree', harness.selected_text())
    harness.press_keys('<C-S-Home>')
    expect_equal('one\nt', harness.selected_text())
    harness.press_keys('<Right>')
end)
test_case('Right at line end wraps to the next line', function()
    start_with_lines({ 'ab', 'cd' }, 1, 2)
    harness.press_keys('<Right>')
    expect_equal({ 2, 0 }, harness.cursor_position())
    harness.press_keys('<Left>')
    expect_equal({ 1, 2 }, harness.cursor_position())
end)
test_case('Ctrl+Right goes to the next word start, Ctrl+Left back', function()
    start_with_lines({ 'foo bar.baz' }, 1, 0)
    harness.press_keys('<C-Right>')
    expect_equal({ 1, 4 }, harness.cursor_position())
    harness.press_keys('<C-Right>')
    expect_equal({ 1, 7 }, harness.cursor_position())
    harness.press_keys('<C-Left>')
    expect_equal({ 1, 4 }, harness.cursor_position())
end)
test_case('Down keeps the column across a short line', function()
    start_with_lines({ 'abcdefgh', 'ab', 'abcdefgh' }, 1, 6)
    harness.press_keys('<Down>')
    expect_equal({ 2, 2 }, harness.cursor_position())
    harness.press_keys('<Down>')
    expect_equal({ 3, 6 }, harness.cursor_position())
end)
test_case('Ctrl+Home / Ctrl+End', function()
    start_with_lines({ 'a', 'b', 'last' }, 2, 0)
    harness.press_keys('<C-End>')
    expect_equal({ 3, 4 }, harness.cursor_position())
    harness.press_keys('<C-Home>')
    expect_equal({ 1, 0 }, harness.cursor_position())
end)

io.write('selection\n')
test_case('Shift+Right selects, typing replaces', function()
    start_with_lines({ 'hello world' }, 1, 0)
    harness.press_keys('<S-Right><S-Right><S-Right>')
    expect_equal('hel', harness.selected_text())
    harness.type_text('J')
    expect_equal('Jlo world', harness.buffer_text())
    expect_equal('i', harness.current_mode())
end)
test_case('Shift+End then Shift+Home', function()
    start_with_lines({ '  abc def' }, 1, 4)
    harness.press_keys('<S-End>')
    expect_equal('c def', harness.selected_text())
    harness.press_keys('<S-Home>')
    expect_equal('ab', harness.selected_text())
end)
test_case('Ctrl+Shift+Right selects to the word end', function()
    start_with_lines({ 'foo bar' }, 1, 0)
    harness.press_keys('<C-S-Right>')
    expect_equal('foo', harness.selected_text())
    harness.press_keys('<C-S-Right>')
    expect_equal('foo bar', harness.selected_text())
end)
test_case('Left collapses to the selection start', function()
    start_with_lines({ 'hello' }, 1, 1)
    harness.press_keys('<S-Right><S-Right>')
    harness.press_keys('<Left>')
    expect_equal('i', harness.current_mode())
    expect_equal({ 1, 1 }, harness.cursor_position())
end)
test_case('Right collapses to the selection end', function()
    start_with_lines({ 'hello' }, 1, 1)
    harness.press_keys('<S-Right><S-Right>')
    harness.press_keys('<Right>')
    expect_equal({ 1, 3 }, harness.cursor_position())
end)
test_case('Ctrl+A selects everything', function()
    start_with_lines({ 'one', 'two' }, 1, 1)
    harness.press_keys('<C-a>')
    expect_equal('one\ntwo', harness.selected_text())
end)
test_case('Backspace deletes the selection', function()
    start_with_lines({ 'hello' }, 1, 0)
    harness.press_keys('<S-End>')
    harness.press_keys('<BS>')
    expect_equal('', harness.buffer_text())
end)
test_case('Delete deletes the selection', function()
    start_with_lines({ 'hello' }, 1, 1)
    harness.press_keys('<S-Right><S-Right>')
    harness.press_keys('<Del>')
    expect_equal('hlo', harness.buffer_text())
    expect_equal({ 1, 1 }, harness.cursor_position())
end)

io.write('clipboard\n')
test_case('Ctrl+C with no selection copies nothing (8.5.3)', function()
    start_with_lines({ 'abc' }, 1, 1)
    harness.set_clipboard_text('keep')
    harness.press_keys('<C-c>')
    expect_equal('keep', harness.clipboard_text())
end)
test_case('Ctrl+C / Ctrl+V', function()
    start_with_lines({ 'hello world' }, 1, 0)
    harness.press_keys('<C-S-Right>')
    harness.press_keys('<C-c>')
    expect_equal('hello', harness.clipboard_text())
    expect_equal('s', harness.current_mode())
    harness.press_keys('<End>')
    harness.press_keys('<C-v>')
    expect_equal('hello worldhello', harness.buffer_text())
    expect_equal({ 1, 16 }, harness.cursor_position())
end)
test_case('Ctrl+X cuts', function()
    start_with_lines({ 'hello world' }, 1, 0)
    harness.press_keys('<C-S-Right>')
    harness.press_keys('<C-x>')
    expect_equal(' world', harness.buffer_text())
    expect_equal('hello', harness.clipboard_text())
end)
test_case('paste over a selection replaces it', function()
    start_with_lines({ 'aaa bbb' }, 1, 4)
    harness.set_clipboard_text('XY')
    harness.press_keys('<S-End>')
    harness.press_keys('<C-v>')
    expect_equal('aaa XY', harness.buffer_text())
end)
test_case('Shift+Insert / Ctrl+Insert / Shift+Del', function()
    start_with_lines({ 'abc' }, 1, 0)
    harness.press_keys('<S-Right>')
    harness.press_keys('<C-Insert>')
    expect_equal('a', harness.clipboard_text())
    harness.press_keys('<S-Del>')
    expect_equal('bc', harness.buffer_text())
    harness.press_keys('<End>')
    harness.press_keys('<S-Insert>')
    expect_equal('bca', harness.buffer_text())
end)
test_case('multi-line paste', function()
    start_with_lines({ 'xy' }, 1, 1)
    harness.set_clipboard_text('1\n2')
    harness.press_keys('<C-v>')
    expect_equal('x1\n2y', harness.buffer_text())
    expect_equal({ 2, 1 }, harness.cursor_position())
end)

io.write('line operations\n')
test_case('Ctrl+D duplicates the line', function()
    start_with_lines({ 'one', 'two' }, 1, 2)
    harness.press_keys('<C-d>')
    expect_equal('one\none\ntwo', harness.buffer_text())
    expect_equal({ 1, 2 }, harness.cursor_position())
end)
test_case('Ctrl+D duplicates the selected text', function()
    start_with_lines({ 'ab' }, 1, 0)
    harness.press_keys('<S-Right>')
    harness.press_keys('<C-d>')
    expect_equal('aab', harness.buffer_text())
    expect_equal('a', harness.selected_text(), 'selection kept')
    harness.press_keys('<Right>')
end)
test_case('Ctrl+L cuts the line; Ctrl+V puts it back above', function()
    start_with_lines({ 'one', 'two', 'three' }, 2, 1)
    harness.press_keys('<C-l>')
    expect_equal('one\nthree', harness.buffer_text())
    expect_equal('two\n', harness.clipboard_text())
    harness.set_cursor_position(1, 2)
    harness.press_keys('<C-v>')
    expect_equal('two\none\nthree', harness.buffer_text())
end)
test_case('Ctrl+Shift+L deletes the caret line only', function()
    start_with_lines({ 'one', 'two', 'three', 'four' }, 2, 1)
    harness.set_clipboard_text('keep')
    harness.press_keys('<S-Down>')
    harness.press_keys('<C-S-l>')
    expect_equal('one\ntwo\nfour', harness.buffer_text())
    expect_equal('keep', harness.clipboard_text())
end)
test_case('Ctrl+Shift+X copies the line', function()
    start_with_lines({ 'one', 'two' }, 2, 1)
    harness.press_keys('<C-S-x>')
    expect_equal('two\n', harness.clipboard_text())
    expect_equal('one\ntwo', harness.buffer_text())
end)
test_case('Ctrl+T swaps with the line above', function()
    start_with_lines({ 'one', 'two' }, 2, 1)
    harness.press_keys('<C-t>')
    expect_equal('two\none', harness.buffer_text())
    expect_equal(2, harness.cursor_position()[1])
end)
test_case('Ctrl+Shift+Up / Down move the line', function()
    start_with_lines({ 'a', 'b', 'c' }, 2, 0)
    harness.press_keys('<C-S-Up>')
    expect_equal('b\na\nc', harness.buffer_text())
    expect_equal(1, harness.cursor_position()[1])
    harness.press_keys('<C-S-Down>')
    harness.press_keys('<C-S-Down>')
    expect_equal('a\nc\nb', harness.buffer_text())
end)
test_case('Ctrl+Alt+Enter / Ctrl+Alt+Shift+Enter blank lines', function()
    start_with_lines({ 'a', 'b' }, 1, 1)
    harness.press_keys('<C-M-CR>')
    expect_equal('\na\nb', harness.buffer_text())
    expect_equal({ 1, 0 }, harness.cursor_position())
    harness.set_cursor_position(2, 1)
    harness.press_keys('<C-M-S-CR>')
    expect_equal('\na\n\nb', harness.buffer_text())
    expect_equal({ 3, 0 }, harness.cursor_position())
end)
test_case('Ctrl+J joins selected lines', function()
    start_with_lines({ 'a', 'b', 'c' }, 1, 0)
    harness.press_keys('<S-Down><S-Down><S-End>')
    harness.press_keys('<C-j>')
    expect_equal('a b c', harness.buffer_text())
end)
test_case('Ctrl+Backspace / Ctrl+Delete delete words', function()
    start_with_lines({ 'foo bar baz' }, 1, 7)
    harness.press_keys('<C-BS>')
    expect_equal('foo  baz', harness.buffer_text())
    harness.press_keys('<C-Del>')
    expect_equal('foo baz', harness.buffer_text())
end)
test_case('Ctrl+Shift+Backspace / Delete to line start / end', function()
    start_with_lines({ 'abcdef' }, 1, 3)
    harness.press_keys('<C-S-BS>')
    expect_equal('def', harness.buffer_text())
    harness.set_cursor_position(1, 1)
    harness.press_keys('<C-S-Del>')
    expect_equal('d', harness.buffer_text())
end)
test_case('Tab indents a multi-line selection, Shift+Tab outdents', function()
    start_with_lines({ 'a', 'b' }, 1, 0)
    harness.press_keys('<S-Down><S-End>')
    harness.press_keys('<Tab>')
    expect_equal('\ta\n\tb', harness.buffer_text())
    expect_equal('s', harness.current_mode())
    harness.press_keys('<S-Tab>')
    expect_equal('a\nb', harness.buffer_text())
end)
test_case('Tab inserts a tab', function()
    start_with_lines({ 'ab' }, 1, 1)
    harness.press_keys('<Tab>')
    expect_equal('a\tb', harness.buffer_text())
end)

io.write('case and comments\n')
test_case('Ctrl+Shift+U, Ctrl+U, Alt+U', function()
    start_with_lines({ 'hello WORLD' }, 1, 0)
    harness.press_keys('<S-End>')
    harness.press_keys('<C-S-u>')
    expect_equal('HELLO WORLD', harness.buffer_text())
    harness.press_keys('<C-u>')
    expect_equal('hello world', harness.buffer_text())
    harness.press_keys('<M-u>')
    expect_equal('Hello World', harness.buffer_text())
end)
test_case('Ctrl+U with no selection changes nothing', function()
    start_with_lines({ 'ABC' }, 1, 1)
    harness.press_keys('<C-u>')
    expect_equal('ABC', harness.buffer_text())
end)
test_case('Ctrl+Alt+U sentence case', function()
    start_with_lines({ 'hELLO there. new ONE' }, 1, 0)
    harness.press_keys('<S-End>')
    harness.press_keys('<C-M-u>')
    expect_equal('Hello there. New one', harness.buffer_text())
end)
test_case('Ctrl+Q toggles // comments per line', function()
    start_with_lines({ 'int a;', '    int b;', '' }, 1, 0)
    harness.run_lua('vim.bo.filetype = "cpp"')
    harness.press_keys('<S-Down><S-Down>')
    harness.press_keys('<C-q>')
    expect_equal('// int a;\n    // int b;\n', harness.buffer_text())
    harness.press_keys('<Esc>')
    harness.set_cursor_position(2, 0)
    harness.press_keys('<C-q>')
    expect_equal('// int a;\n    int b;\n', harness.buffer_text())
end)
test_case('Ctrl+K comments the selected lines per language', function()
    start_with_lines({ 'a', 'b', 'c' }, 1, 0)
    harness.run_lua('vim.bo.filetype = "sql"')
    harness.press_keys('<S-Down>')
    harness.press_keys('<S-Right>')
    harness.press_keys('<C-k>')
    expect_equal('-- a\n-- b\nc', harness.buffer_text())
    start_with_lines({ 'a' }, 1, 0)
    harness.run_lua('vim.bo.filetype = "markdown"')
    harness.press_keys('<C-k>')
    expect_equal('<!-- a -->', harness.buffer_text())
    start_with_lines({ 'a' }, 1, 0)
    harness.run_lua('vim.bo.filetype = "text"')
    harness.press_keys('<C-k>')
    expect_equal('a', harness.buffer_text(), 'Normal Text has no comment')
    harness.run_lua('vim.bo.filetype = ""')
end)
test_case('Ctrl+K / Ctrl+Shift+K', function()
    start_with_lines({ 'x = 1' }, 1, 0)
    harness.run_lua('vim.bo.filetype = "python"')
    harness.press_keys('<C-k>')
    expect_equal('# x = 1', harness.buffer_text())
    harness.press_keys('<C-S-k>')
    expect_equal('x = 1', harness.buffer_text())
end)
test_case('Ctrl+Shift+Q block comment', function()
    start_with_lines({ 'a = 1;' }, 1, 0)
    harness.run_lua('vim.bo.filetype = "c"')
    harness.press_keys('<C-S-Right>')
    harness.press_keys('<C-S-q>')
    expect_equal('/* a */ = 1;', harness.buffer_text())
end)

io.write('search\n')
test_case('Find dialog: Enter finds next, Esc leaves the match selected', function()
    start_with_lines({ 'alpha beta', 'gamma beta' }, 1, 0)
    harness.press_keys('<C-f>')
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, {"beta"})')
    harness.press_keys('<CR>')
    harness.press_keys('<CR>')
    harness.press_keys('<Esc>')
    expect_equal('beta', harness.selected_text())
    expect_equal({ 2, 10 }, harness.cursor_position())
    harness.type_text('X')
    expect_equal('alpha beta\ngamma X', harness.buffer_text())
end)
test_case('F3 / Shift+F3 use the last search', function()
    start_with_lines({ 'a1 a2 a3' }, 1, 0)
    harness.run_lua(
        'local find_and_replace = require("notebashpp.find_and_replace"); find_and_replace.state.find = "a\\\\d"; find_and_replace.state.mode = "regex"'
    )
    harness.press_keys('<F3>')
    expect_equal('a1', harness.selected_text())
    harness.press_keys('<F3>')
    expect_equal('a2', harness.selected_text())
    harness.press_keys('<S-F3>')
    expect_equal('a1', harness.selected_text())
end)
test_case('Find wraps around', function()
    start_with_lines({ 'x', 'y x' }, 2, 3)
    harness.run_lua(
        'local find_and_replace = require("notebashpp.find_and_replace"); find_and_replace.state.find = "x"; find_and_replace.state.mode = "normal"'
    )
    harness.press_keys('<F3>')
    expect_equal({ 1, 1 }, harness.cursor_position())
end)
test_case('Ctrl+F fills Find what with the word, selected; typing replaces it', function()
    start_with_lines({ 'alpha beta', 'gamma' }, 1, 2)
    harness.press_keys('<C-f>', 100)
    expect_equal('s', harness.current_mode(), 'text selected')
    harness.type_text('beta')
    expect_equal('beta', harness.run_lua('return vim.api.nvim_get_current_line()'))
    harness.press_keys('<Esc>', 100)
    harness.press_keys('<C-h>', 100)
    harness.press_keys('<Tab>')
    expect_equal('i', harness.current_mode(), 'Tab drops the selection')
    harness.type_text('Z')
    expect_equal({ 'alpha', 'Z' }, harness.run_lua('return vim.api.nvim_buf_get_lines(0, 0, -1, false)'), 'Ctrl+H refills the word at the caret')
    harness.press_keys('<Esc>', 100)
    expect_equal(false, harness.run_lua('return require("notebashpp.find_and_replace").dialog_open()'), 'dialog closed')
    harness.run_lua('require("notebashpp.find_and_replace").state.replace = ""')
end)
test_case('Ctrl+F3 selects the word and finds the next one', function()
    start_with_lines({ 'cat dog cat' }, 1, 1)
    harness.press_keys('<C-F3>')
    expect_equal('cat', harness.selected_text())
    expect_equal({ 1, 11 }, harness.cursor_position())
end)
test_case('Replace All with regex groups', function()
    start_with_lines({ 'a1 b2', 'c3' }, 1, 0)
    harness.run_lua([[local find_and_replace = require("notebashpp.find_and_replace")
        find_and_replace.state.find = "(\\w)(\\d)"; find_and_replace.state.replace = "$2\\1"; find_and_replace.state.mode = "regex"; find_and_replace.state.in_selection = false; find_and_replace.state.wrap = true
        find_and_replace.replace_all(false)]])
    harness.wait_until_idle()
    expect_equal('1a 2b\n3c', harness.buffer_text())
end)
test_case('Replace All with \\r\\n in the replacement', function()
    start_with_lines({ 'a,b,c' }, 1, 0)
    harness.run_lua([[local find_and_replace = require("notebashpp.find_and_replace")
        find_and_replace.state.find = ","; find_and_replace.state.replace = "\\r\\n"; find_and_replace.state.mode = "extended"
        find_and_replace.replace_all(false)]])
    harness.wait_until_idle()
    expect_equal('a\nb\nc', harness.buffer_text())
end)
test_case('Replace dialog: Alt+A replaces all', function()
    start_with_lines({ 'foo foo', 'foo' }, 1, 0)
    harness.press_keys('<C-h>')
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, {"foo", "bar"})')
    harness.press_keys('<M-n>')
    harness.press_keys('<M-a>')
    harness.press_keys('<Esc>')
    expect_equal('bar bar\nbar', harness.buffer_text())
end)
test_case('Count', function()
    start_with_lines({ 'aXa', 'Xa' }, 1, 0)
    harness.run_lua(
        [[local find_and_replace = require("notebashpp.find_and_replace"); find_and_replace.state.find = "x"; find_and_replace.state.mode = "normal"; find_and_replace.state.match_case = false; find_and_replace.count()]]
    )
end)
test_case('Find All in Current Document fills the results panel', function()
    start_with_lines({ 'one', 'two one', 'three' }, 1, 0)
    harness.run_lua(
        [[local find_and_replace = require("notebashpp.find_and_replace"); find_and_replace.state.find = "one"; find_and_replace.state.mode = "normal"; find_and_replace.find_all(false)]]
    )
    harness.wait_until_idle()
    expect_equal(2, harness.run_lua('return vim.fn.getqflist({size=0}).size'))
    harness.press_keys('<F4>')
    expect_equal({ 2, 4 }, harness.cursor_position())
end)
test_case('Ctrl+G goes to a line', function()
    start_with_lines({ 'a', 'b', 'c' }, 1, 0)
    harness.press_keys('<C-g>')
    harness.press_keys('3<CR>')
    expect_equal(3, harness.cursor_position()[1])
end)
test_case('Ctrl+B jumps between braces', function()
    start_with_lines({ 'f(a, (b))' }, 1, 2)
    harness.press_keys('<C-b>')
    expect_equal({ 1, 8 }, harness.cursor_position())
    -- check the character before the caret first, as in notepad++. basically
    -- even brace matching looks back for where it all went to shit.
    harness.press_keys('<C-b>')
    expect_equal({ 1, 5 }, harness.cursor_position())
end)
test_case('Ctrl+Alt+B selects between braces', function()
    start_with_lines({ 'x[abc]y' }, 1, 1)
    harness.press_keys('<C-M-b>')
    expect_equal('[abc]', harness.selected_text())
end)

io.write('bookmarks, macros, column mode\n')
test_case('Ctrl+F2 / F2 / Shift+F2 bookmarks', function()
    start_with_lines({ 'a', 'b', 'c', 'd' }, 2, 0)
    harness.press_keys('<C-F2>')
    harness.set_cursor_position(4, 0)
    harness.press_keys('<C-F2>')
    harness.set_cursor_position(1, 0)
    harness.press_keys('<F2>')
    expect_equal(2, harness.cursor_position()[1])
    harness.press_keys('<F2>')
    expect_equal(4, harness.cursor_position()[1])
    harness.press_keys('<F2>')
    expect_equal(2, harness.cursor_position()[1])
    harness.press_keys('<S-F2>')
    expect_equal(4, harness.cursor_position()[1])
end)
test_case('terminal codes for Ctrl+F2 and Shift+F2 work and unbound ones type nothing', function()
    start_with_lines({ 'a', 'b', 'c', 'd' }, 2, 0)
    harness.press_keys('<F26>')
    harness.set_cursor_position(4, 0)
    harness.press_keys('<F26>')
    harness.set_cursor_position(1, 0)
    harness.press_keys('<F2>')
    expect_equal(2, harness.cursor_position()[1], 'ctrl+f2 sent as f26 set a bookmark')
    harness.set_cursor_position(1, 0)
    harness.press_keys('<F14>')
    expect_equal(4, harness.cursor_position()[1], 'shift+f2 sent as f14 went to the previous bookmark')
    harness.press_keys('<F60><F71>')
    expect_equal('a\nb\nc\nd', harness.buffer_text(), 'unbound codes typed nothing')
end)
test_case('Ctrl+Shift+R records, Ctrl+Shift+P plays back', function()
    start_with_lines({ 'a', 'b', 'c' }, 1, 0)
    harness.press_keys('<C-S-r>')
    harness.press_keys('<End>')
    harness.type_text(';')
    harness.press_keys('<Down>')
    harness.press_keys('<C-S-r>')
    harness.press_keys('<C-S-p>')
    harness.press_keys('<C-S-p>')
    expect_equal('a;\nb;\nc;', harness.buffer_text())
end)
test_case('Alt+Shift+Down then typing writes on every line', function()
    start_with_lines({ 'abc', 'abc', 'abc' }, 1, 1)
    harness.press_keys('<M-S-Down><M-S-Down>')
    harness.type_text('XY')
    expect_equal('aXYbc\naXYbc\naXYbc', harness.buffer_text())
    harness.press_keys('<BS>')
    expect_equal('aXbc\naXbc\naXbc', harness.buffer_text())
end)
test_case('Column selection, Ctrl+C copies the block, Delete clears it', function()
    start_with_lines({ 'abcd', 'efgh' }, 1, 1)
    harness.press_keys('<M-S-Down><M-S-Right><M-S-Right>')
    harness.press_keys('<C-c>')
    expect_equal('bc\nfg', harness.clipboard_text())
    harness.press_keys('<Del>')
    expect_equal('ad\neh', harness.buffer_text())
end)
test_case('Alt+Shift+S trims trailing space and saves', function()
    local file_path = harness.temporary_directory .. '/trim.txt'
    harness.run_lua('vim.cmd.edit(...)', file_path)
    harness.wait_until_idle()
    start_with_lines({ 'a   ', 'b\t' }, 1, 0)
    harness.press_keys('<M-S>')
    expect_equal('a\nb', harness.buffer_text())
    expect_equal(false, harness.run_lua('return vim.bo.modified'))
end)

io.write('multi-editing\n')
-- press the mouse at a buffer position with modifiers (c for ctrl), as a
-- terminal or neovide reports it. screen rows & columns use the window's
-- position, its window bar and the text's display width. all this crap just
-- to establish where i clicked.
local function mouse_at(line_number, byte_column, action, modifiers)
    local screen_position = harness.run_lua(
        [[
        local line_number, byte_column = ...
        local window_info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
        local line_text = vim.api.nvim_buf_get_lines(0, line_number - 1, line_number, false)[1]
        local row = window_info.winrow + window_info.winbar + line_number - window_info.topline
        local column = window_info.wincol + window_info.textoff + vim.fn.strdisplaywidth(line_text:sub(1, byte_column))
        return { row - 1, column - 1 }
    ]],
        line_number,
        byte_column
    )
    harness.request('nvim_input_mouse', 'left', action, modifiers or '', 0, screen_position[1], screen_position[2])
end
local function ctrl_click(line_number, byte_column)
    mouse_at(line_number, byte_column, 'press', 'C')
    mouse_at(line_number, byte_column, 'release', 'C')
    harness.wait_until_idle()
end
local function carets()
    return harness.run_lua([[
        local caret_list = {}
        for _, caret in ipairs(require('notebashpp.multi_editing').carets()) do
            caret_list[#caret_list + 1] = { caret.anchor[1], caret.anchor[2], caret.head[1], caret.head[2] }
        end
        return caret_list
    ]])
end
local function caret_count()
    return harness.run_lua('return require("notebashpp.multi_editing").caret_count()')
end
test_case('Ctrl+click adds carets; typing goes to every caret', function()
    start_with_lines({ 'abc', 'abc', 'abc' }, 1, 1)
    ctrl_click(2, 2)
    ctrl_click(3, 3)
    expect_equal({ { 1, 1, 1, 1 }, { 2, 2, 2, 2 }, { 3, 3, 3, 3 } }, carets())
    harness.type_text('XY')
    expect_equal('aXYbc\nabXYc\nabcXY', harness.buffer_text())
    expect_equal({ 3, 5 }, harness.cursor_position(), 'the real cursor is the caret added last')
    expect_equal('i', harness.current_mode())
end)
test_case('Ctrl+click on a caret removes it', function()
    start_with_lines({ 'abc', 'abc', 'abc' }, 1, 0)
    ctrl_click(2, 1)
    ctrl_click(3, 1)
    ctrl_click(2, 1)
    expect_equal({ { 1, 0, 1, 0 }, { 3, 1, 3, 1 } }, carets())
    ctrl_click(1, 0)
    expect_equal(1, caret_count(), 'down to one caret')
    expect_equal({ 3, 1 }, harness.cursor_position())
end)
test_case('Backspace and Delete at line starts and ends, at every caret', function()
    start_with_lines({ 'ab', 'cd', 'ef' }, 2, 0)
    ctrl_click(3, 0)
    harness.press_keys('<BS>')
    expect_equal('abcdef', harness.buffer_text(), 'Backspace at line starts joins lines')
    expect_equal({ { 1, 2, 1, 2 }, { 1, 4, 1, 4 } }, carets())
    start_with_lines({ 'ab', 'cd', 'ef' }, 1, 2)
    ctrl_click(2, 2)
    harness.press_keys('<Del>')
    expect_equal('abcdef', harness.buffer_text(), 'Delete at line ends joins lines')
    harness.press_keys('<Del>')
    expect_equal('abdf', harness.buffer_text(), 'Delete in the middle')
    harness.press_keys('<BS>')
    expect_equal('af', harness.buffer_text(), 'Backspace in the middle')
    start_with_lines({ 'one two', 'one two' }, 1, 7)
    ctrl_click(2, 7)
    harness.press_keys('<C-BS>')
    expect_equal('one \none ', harness.buffer_text(), 'Ctrl+Backspace')
end)
test_case('Enter at every caret keeps the indentation', function()
    start_with_lines({ '  ab', '  cd' }, 1, 3)
    ctrl_click(2, 3)
    harness.press_keys('<CR>')
    expect_equal('  a\n  b\n  c\n  d', harness.buffer_text())
    expect_equal({ { 2, 2, 2, 2 }, { 4, 2, 4, 2 } }, carets())
end)
test_case('Shift+arrows give each caret its own selection; typing replaces them', function()
    start_with_lines({ 'abcd', 'abcd' }, 1, 0)
    ctrl_click(2, 1)
    harness.press_keys('<S-Right><S-Right>')
    expect_equal({ { 1, 0, 1, 2 }, { 2, 1, 2, 3 } }, carets())
    harness.press_keys('<C-c>')
    expect_equal('ab\nbc', harness.clipboard_text(), 'Ctrl+C copies every selection')
    harness.type_text('X')
    expect_equal('Xcd\naXd', harness.buffer_text())
    harness.press_keys('<End>')
    harness.type_text('!')
    expect_equal('Xcd!\naXd!', harness.buffer_text())
end)
test_case('paste gives one clipboard line per caret, or the whole text to each', function()
    start_with_lines({ 'a', 'b' }, 1, 1)
    ctrl_click(2, 1)
    harness.set_clipboard_text('1\n2')
    harness.press_keys('<C-v>')
    expect_equal('a1\nb2', harness.buffer_text(), 'line counts match')
    harness.set_clipboard_text('xy')
    harness.press_keys('<C-v>')
    expect_equal('a1xy\nb2xy', harness.buffer_text(), 'one line')
    harness.set_clipboard_text('1\n2\n3')
    harness.press_keys('<C-v>')
    expect_equal('a1xy1\n2\n3\nb2xy1\n2\n3', harness.buffer_text(), 'line counts differ')
    expect_equal(2, caret_count())
end)
test_case('one Ctrl+Z undoes a multi-caret typing run; Esc goes back to one caret', function()
    start_with_lines({ 'abc', 'abc', 'abc' }, 1, 0)
    ctrl_click(2, 0)
    ctrl_click(3, 0)
    harness.type_text('XY')
    harness.press_keys('<BS>')
    expect_equal('Xabc\nXabc\nXabc', harness.buffer_text())
    harness.press_keys('<C-z>')
    expect_equal('abc\nabc\nabc', harness.buffer_text(), 'one undo step')
    expect_equal(1, caret_count(), 'undo ends multi-editing')
    harness.press_keys('<C-y>')
    expect_equal('Xabc\nXabc\nXabc', harness.buffer_text(), 'redo')
    start_with_lines({ 'abc', 'abc' }, 1, 1)
    ctrl_click(2, 2)
    harness.press_keys('<Esc>')
    expect_equal(1, caret_count(), 'Esc')
    expect_equal('i', harness.current_mode())
    harness.type_text('Z')
    expect_equal('abc\nabZc', harness.buffer_text(), 'typing after Esc goes to the main caret only')
    ctrl_click(1, 0)
    mouse_at(1, 2, 'press')
    mouse_at(1, 2, 'release')
    harness.wait_until_idle()
    expect_equal(1, caret_count(), 'a plain click')
    expect_equal({ 1, 2 }, harness.cursor_position())
end)
test_case('carets that meet merge into one', function()
    start_with_lines({ 'abcdef', 'abcdef' }, 1, 1)
    ctrl_click(1, 3)
    ctrl_click(2, 2)
    harness.press_keys('<Home>')
    expect_equal({ { 1, 0, 1, 0 }, { 2, 0, 2, 0 } }, carets(), 'two carets at the same spot merged')
    ctrl_click(1, 2)
    harness.press_keys('<S-Right><S-Right>')
    expect_equal({ { 1, 0, 1, 2 }, { 1, 2, 1, 4 }, { 2, 0, 2, 2 } }, carets(), 'touching selections stay apart')
    harness.press_keys('<S-Right>')
    expect_equal({ { 1, 0, 1, 5 }, { 2, 0, 2, 3 } }, carets(), 'overlapping selections merged')
    harness.press_keys('<C-Home>')
    expect_equal(1, caret_count(), 'every caret at the document start')
    expect_equal({ 1, 0 }, harness.cursor_position())
end)
test_case('Ctrl+drag and Ctrl+double-click add selections', function()
    start_with_lines({ 'one two', 'three four' }, 1, 0)
    mouse_at(2, 0, 'press', 'C')
    mouse_at(2, 3, 'drag', 'C')
    mouse_at(2, 3, 'release', 'C')
    harness.wait_until_idle()
    expect_equal({ { 1, 0, 1, 0 }, { 2, 0, 2, 3 } }, carets())
    ctrl_click(1, 5)
    mouse_at(1, 5, 'press', 'C')
    mouse_at(1, 5, 'release', 'C')
    harness.wait_until_idle()
    expect_equal({ { 1, 0, 1, 0 }, { 1, 4, 1, 7 }, { 2, 0, 2, 3 } }, carets())
    harness.type_text('_')
    expect_equal('_one _\n_ee four', harness.buffer_text())
end)
test_case('Multi-select Next (Ctrl+E) and Multi-select All (Ctrl+Shift+E)', function()
    start_with_lines({ 'foo Foo foo', 'food foo' }, 1, 1)
    harness.press_keys('<C-e>')
    expect_equal('foo', harness.selected_text(), 'first press selects the word')
    harness.press_keys('<C-e>')
    expect_equal({ { 1, 0, 1, 3 }, { 1, 8, 1, 11 } }, carets(), 'match case skips Foo')
    harness.press_keys('<C-e>')
    harness.press_keys('<C-e>')
    expect_equal({ { 1, 0, 1, 3 }, { 1, 8, 1, 11 }, { 2, 0, 2, 3 }, { 2, 5, 2, 8 } }, carets(), 'not whole word: food counts')
    harness.press_keys('<C-e>')
    expect_equal(4, caret_count(), 'nothing left to add')
    harness.run_lua('require("notebashpp.keybindings").run("multi_select_undo")')
    harness.wait_until_idle()
    expect_equal(3, caret_count(), 'undo the latest added')
    harness.type_text('X')
    expect_equal('X Foo X\nXd foo', harness.buffer_text())
    start_with_lines({ 'foo Foo foo', 'food foo' }, 1, 1)
    harness.run_lua('require("notebashpp.keybindings").run("multi_select_all_whole_word")')
    harness.wait_until_idle()
    harness.run_lua('require("notebashpp.keybindings").run("multi_select_all_whole_word")')
    harness.wait_until_idle()
    expect_equal({ { 1, 0, 1, 3 }, { 1, 4, 1, 7 }, { 1, 8, 1, 11 }, { 2, 5, 2, 8 } }, carets(), 'whole word, any case')
    start_with_lines({ 'foo Foo foo', 'food foo' }, 1, 8)
    harness.press_keys('<C-S-Right>')
    harness.press_keys('<C-S-e>')
    expect_equal(4, caret_count(), 'Ctrl+Shift+E: match case only')
    expect_equal({ 1, 11 }, harness.cursor_position(), 'the main caret stays put')
end)
test_case('Hebrew and emoji at several carets', function()
    start_with_lines({ 'שלום', '😀x' }, 1, 0)
    ctrl_click(2, 0)
    harness.press_keys('<Right>')
    expect_equal({ { 1, 2, 1, 2 }, { 2, 4, 2, 4 } }, carets(), 'Right steps over one whole character')
    harness.type_text('א')
    expect_equal('שאלום\n😀אx', harness.buffer_text())
    harness.press_keys('<BS><BS>')
    expect_equal('לום\nx', harness.buffer_text())
    harness.press_keys('<S-End>')
    harness.type_text('🎉')
    expect_equal('🎉\n🎉', harness.buffer_text())
    harness.press_keys('<S-Left><Del>')
    expect_equal('\n', harness.buffer_text())
end)
test_case('Column mode to carets, and Alt+Shift+arrows end multi-editing', function()
    start_with_lines({ 'abcd', 'abcd', 'ab' }, 1, 1)
    harness.press_keys('<M-S-Down><M-S-Down><M-S-Right>')
    harness.run_lua('require("notebashpp.keybindings").run("column_to_carets")')
    harness.wait_until_idle()
    expect_equal({ { 1, 1, 1, 2 }, { 2, 1, 2, 2 }, { 3, 1, 3, 2 } }, carets())
    harness.press_keys('<S-Right>')
    harness.type_text('_')
    expect_equal('a_d\na_d\na_', harness.buffer_text())
    harness.press_keys('<M-S-Up>')
    expect_equal(1, caret_count(), 'column mode took over')
    harness.press_keys('<Esc>')
end)
test_case('a macro recorded with several carets plays back', function()
    start_with_lines({ 'foo foo', 'bar' }, 1, 0)
    harness.press_keys('<C-S-r>')
    harness.press_keys('<C-e><C-e>')
    harness.type_text('ab')
    harness.press_keys('<BS><Esc><Down>')
    harness.type_text('Z')
    harness.press_keys('<C-S-r>')
    expect_equal('a a\nbarZ', harness.buffer_text())
    start_with_lines({ 'foo x foo', 'bar' }, 1, 0)
    harness.press_keys('<C-S-p>')
    expect_equal('a x a\nbarZ', harness.buffer_text())
end)
test_case('a live code reload keeps the carets', function()
    start_with_lines({ 'one one' }, 1, 0)
    harness.press_keys('<C-e><C-e>')
    expect_equal(2, caret_count())
    expect_equal(true, harness.run_lua('return require("notebashpp.live_code_reload").reload({ "multi_editing.lua" })'))
    harness.wait_until_idle()
    expect_equal(2, caret_count(), 'kept')
    harness.type_text('2')
    expect_equal('2 2', harness.buffer_text())
end)
test_case('typing with 1,000 carets in a 10,000-line file stays quick', function()
    local lines = {}
    for line_number = 1, 10000 do
        lines[line_number] = line_number % 10 == 0 and ('target ' .. line_number) or ('plain line ' .. line_number)
    end
    start_with_lines(lines, 10, 0)
    harness.press_keys('<C-S-Right><C-S-e>')
    expect_equal(1000, caret_count())
    local started_at = vim.uv.hrtime()
    harness.type_text('X')
    harness.press_keys('<BS>')
    harness.type_text('Y')
    local elapsed_milliseconds = (vim.uv.hrtime() - started_at) / 1e6
    expect_equal(true, elapsed_milliseconds < 1500, ('three keys took %d ms'):format(elapsed_milliseconds))
    expect_equal({ 'Y 10', 'plain line 11' }, harness.run_lua('return vim.api.nvim_buf_get_lines(0, 9, 11, false)'))
    expect_equal('Y 10000', harness.run_lua('return vim.api.nvim_buf_get_lines(0, 9999, 10000, false)[1]'))
    harness.press_keys('<Esc>')
end)

io.write('files and tabs\n')
test_case('Ctrl+N opens "new 2"; Ctrl+Tab goes back', function()
    harness.run_lua('vim.cmd("silent! %bwipeout!")')
    harness.wait_until_idle()
    local first_buffer = harness.run_lua('return vim.api.nvim_get_current_buf()')
    harness.press_keys('<C-n>')
    local second_buffer = harness.run_lua('return vim.api.nvim_get_current_buf()')
    expect_equal(true, first_buffer ~= second_buffer, 'new buffer')
    expect_equal('new 2', harness.run_lua('return require("notebashpp.document_tabs").name(0 + vim.api.nvim_get_current_buf())'))
    harness.press_keys('<C-Tab>')
    expect_equal(first_buffer, harness.run_lua('return vim.api.nvim_get_current_buf()'))
end)
test_case('Ctrl+PageDown / Ctrl+PageUp cycle tabs', function()
    local tab_order = harness.run_lua('return require("notebashpp.document_tabs").sync()')
    harness.run_lua('vim.api.nvim_set_current_buf(...)', tab_order[1])
    harness.wait_until_idle()
    harness.press_keys('<C-PageDown>')
    expect_equal(tab_order[2], harness.run_lua('return vim.api.nvim_get_current_buf()'))
    harness.press_keys('<C-PageUp>')
    expect_equal(tab_order[1], harness.run_lua('return vim.api.nvim_get_current_buf()'))
end)
test_case('Ctrl+S saves, Ctrl+W closes', function()
    local file_path = harness.temporary_directory .. '/save.txt'
    harness.run_lua('vim.cmd.edit(...)', file_path)
    harness.wait_until_idle()
    harness.type_text('saved text')
    harness.press_keys('<C-s>')
    expect_equal({ 'saved text' }, vim.fn.readfile(file_path))
    harness.press_keys('<C-w>')
    expect_equal(false, harness.run_lua('return vim.api.nvim_buf_get_name(0) == ...', file_path))
end)
test_case('Ctrl+Shift+T reopens the closed file', function()
    harness.press_keys('<C-S-t>')
    -- macos temp files live under /var, really /private/var. resolve symlinks
    -- on both sides before comparing. even a damn path needs an alias to
    -- cope.
    expect_equal(vim.fn.resolve(harness.temporary_directory .. '/save.txt'), harness.run_lua('return vim.fn.resolve(vim.api.nvim_buf_get_name(0))'))
end)

io.write('menus\n')
test_case('Alt+E opens the Edit menu; letters run items', function()
    start_with_lines({ 'abc' }, 1, 0)
    harness.press_keys('<S-End>')
    harness.press_keys('<M-e>')
    expect_equal('notebashpp_menu', harness.run_lua('return vim.bo.filetype'))
    harness.press_keys('v')
    harness.press_keys('u')
    expect_equal('ABC', harness.buffer_text())
end)
test_case('Esc closes a menu and returns to typing', function()
    start_with_lines({ 'abc' }, 1, 2)
    harness.press_keys('<M-f>')
    harness.press_keys('<Esc>')
    expect_equal('i', harness.current_mode())
    expect_equal({ 1, 2 }, harness.cursor_position())
end)
test_case('menu arrow keys and Enter', function()
    start_with_lines({ 'abc' }, 1, 0)
    harness.press_keys('<M-v>')
    harness.press_keys('<Right>')
    expect_equal('notebashpp_menu', harness.run_lua('return vim.bo.filetype'))
    harness.press_keys('<Esc>')
    harness.press_keys('<Esc>')
    expect_equal('i', harness.current_mode())
end)

test_case('a shortcut pressed in an open menu closes it', function()
    start_with_lines({ 'abc' }, 1, 1)
    harness.press_keys('<M-s>')
    harness.press_keys('<C-f>')
    expect_equal('notebashpp_find', harness.run_lua('return vim.bo.filetype'))
    harness.press_keys('<Esc>')
    expect_equal(
        0,
        harness.run_lua([[local floating_window_count = 0
        for _, window in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(window).relative ~= '' and not vim.w[window].notebashpp_notification then
                floating_window_count = floating_window_count + 1
            end
        end
        return floating_window_count]])
    )
    expect_equal('i', harness.current_mode())
end)

io.write('view\n')
test_case('Alt+H hides lines', function()
    start_with_lines({ 'a', 'b', 'c', 'd' }, 2, 0)
    harness.press_keys('<S-Down>')
    harness.press_keys('<M-h>')
    expect_equal(
        1,
        harness.run_lua('return #vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("notebashpp_hidden"), 0, -1, {details=true}) > 0 and 1 or 0')
    )
end)
test_case('Ctrl+Alt+R sets right-to-left, Ctrl+Alt+L back', function()
    harness.press_keys('<C-M-r>')
    expect_equal(true, harness.run_lua('return vim.wo.rightleft'))
    harness.press_keys('<C-M-l>')
    expect_equal(false, harness.run_lua('return vim.wo.rightleft'))
end)
test_case('Ctrl+S, Ctrl+C, Alt+U also work with the Hebrew layout on', function()
    start_with_lines({ 'abc def' }, 1, 0)
    harness.press_keys('<C-S-Right>')
    harness.press_keys('<C-ב>')
    expect_equal('abc', harness.clipboard_text())
    harness.press_keys('<M-ו>')
    expect_equal('Abc def', harness.buffer_text())
    expect_equal(true, harness.run_lua('return vim.fn.maparg("<C-ד>", "i") ~= ""'), 'Ctrl+S alias')
    expect_equal(true, harness.run_lua('return vim.fn.maparg("<C-س>", "i") ~= ""'), 'Arabic alias')
end)
test_case('unbound Alt keys do nothing', function()
    start_with_lines({ 'abc' }, 1, 1)
    harness.press_keys('<M-j>')
    harness.press_keys('<M-q>')
    expect_equal('i', harness.current_mode())
    expect_equal('abc', harness.buffer_text())
end)

io.write('completion\n')
test_case('typing a word prefix shows the word list; Enter takes it', function()
    start_with_lines({ 'elephant eleven', '' }, 2, 0)
    harness.type_text('ele')
    expect_equal(1, harness.run_lua('return vim.fn.pumvisible()'))
    harness.press_keys('<Down>')
    harness.press_keys('<CR>')
    expect_equal('elephant eleven\neleven', harness.buffer_text())
end)
test_case('arrows do not open the list; Esc closes it', function()
    start_with_lines({ 'alpha', 'al' }, 2, 2)
    harness.press_keys('<Left>')
    expect_equal(0, harness.run_lua('return vim.fn.pumvisible()'))
    harness.press_keys('<End>')
    harness.type_text('p')
    expect_equal(1, harness.run_lua('return vim.fn.pumvisible()'))
    harness.press_keys('<Esc>')
    expect_equal(0, harness.run_lua('return vim.fn.pumvisible()'))
    expect_equal('alpha\nalp', harness.buffer_text())
end)
test_case('numbers do not open the list', function()
    start_with_lines({ '12345', '' }, 2, 0)
    harness.type_text('12')
    expect_equal(0, harness.run_lua('return vim.fn.pumvisible()'))
end)

io.write('more search\n')
test_case('Replace All in selection only', function()
    start_with_lines({ 'x x', 'x x', 'x x' }, 2, 0)
    harness.press_keys('<S-End>')
    harness.press_keys('<C-h>')
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, {"x", "y"})')
    harness.press_keys('<M-n>')
    harness.press_keys('<M-i>')
    expect_equal(true, harness.run_lua('return require("notebashpp.find_and_replace").state.in_selection'), 'in selection on')
    harness.press_keys('<M-a>')
    harness.press_keys('<Esc>')
    expect_equal('x x\ny y\nx x', harness.buffer_text())
end)
test_case('Find in Files lists hits from ripgrep', function()
    local search_directory = harness.temporary_directory .. '/fif'
    vim.fn.mkdir(search_directory, 'p')
    vim.fn.writefile({ 'needle one', 'hay' }, search_directory .. '/a.txt')
    vim.fn.writefile({ 'no', 'needle two' }, search_directory .. '/b.go')
    harness.run_lua(
        [[local find_and_replace = require("notebashpp.find_and_replace")
        find_and_replace.state.find = "needle"; find_and_replace.state.mode = "normal"; find_and_replace.state.dir = ...; find_and_replace.state.filters = "*.*"
        find_and_replace.find_in_files()]],
        search_directory
    )
    harness.wait_until_idle(800)
    expect_equal(2, harness.run_lua('return vim.fn.getqflist({size=0}).size'))
    harness.run_lua('vim.cmd("cclose")')
end)
test_case('Find in Files stops at its hit limit instead of eating all the memory', function()
    local search_directory = harness.temporary_directory .. '/fif-many'
    vim.fn.mkdir(search_directory, 'p')
    local many_lines = {}
    for line_number = 1, 5000 do
        many_lines[line_number] = 'needle ' .. line_number
    end
    vim.fn.writefile(many_lines, search_directory .. '/many.txt')
    harness.run_lua(
        [[local find_and_replace = require("notebashpp.find_and_replace")
        find_and_replace.ripgrep_limits.hits = 300
        find_and_replace.state.find = "needle"; find_and_replace.state.mode = "normal"; find_and_replace.state.dir = ...; find_and_replace.state.filters = "*.*"
        find_and_replace.find_in_files()]],
        search_directory
    )
    harness.wait_until_idle(1500)
    expect_equal(300, harness.run_lua('return vim.fn.getqflist({size=0}).size'))
    expect_equal(true, harness.run_lua('return vim.fn.getqflist({title=0}).title:find("stopped at 300 hits", 1, true) ~= nil'))
    harness.run_lua('require("notebashpp.find_and_replace").ripgrep_limits.hits = 10000; vim.cmd("cclose")')
end)
test_case('Replace in Files refuses when too many files match', function()
    local search_directory = harness.temporary_directory .. '/rif-many'
    vim.fn.mkdir(search_directory, 'p')
    for file_number = 1, 5 do
        vim.fn.writefile({ 'needle' }, search_directory .. '/f' .. file_number .. '.txt')
    end
    harness.run_lua(
        [[local find_and_replace = require("notebashpp.find_and_replace")
        find_and_replace.ripgrep_limits.hits = 3
        find_and_replace.state.find = "needle"; find_and_replace.state.replace = "pin"; find_and_replace.state.mode = "normal"; find_and_replace.state.dir = ...; find_and_replace.state.filters = "*.*"
        local real_confirm = vim.fn.confirm
        vim.fn.confirm = function() return 1 end
        find_and_replace.replace_in_files()
        vim.fn.confirm = real_confirm]],
        search_directory
    )
    harness.wait_until_idle(1500)
    expect_equal({ 'needle' }, vim.fn.readfile(search_directory .. '/f1.txt'), 'nothing replaced')
    harness.run_lua(
        'local find_and_replace = require("notebashpp.find_and_replace"); find_and_replace.ripgrep_limits.hits = 10000; find_and_replace.state.replace = ""'
    )
end)
test_case('regex translation', function()
    local translations = harness.run_lua([[local regex = require("notebashpp.notepadpp_regex")
        return { regex.pcre("a+?b{2,}(?:x|y)\\d"), regex.pcre("(?<=a)b"), regex.pcre("^\\s*$"), regex.literal("a\\b.c"), regex.pcre("<x=1>") }]])
    expect_equal('\\va{-1,}b{2,}%(x|y)\\d', translations[1])
    expect_equal('\\v%(a)@<=b', translations[2])
    expect_equal('\\v^\\s*$', translations[3])
    expect_equal('\\Va\\\\b.c', translations[4])
    expect_equal('\\v\\<x\\=1\\>', translations[5])
end)

io.write('column editor\n')
test_case('Alt+C inserts numbers down a column', function()
    start_with_lines({ 'a', 'b', 'c' }, 1, 1)
    harness.press_keys('<M-c>')
    for _ = 1, 6 do
        harness.press_keys('<CR>')
    end
    expect_equal('a1\nb2\nc3', harness.buffer_text())
end)

io.write('session\n')
test_case('unsaved work comes back after a restart', function()
    harness.stop_editor()
    harness.start_editor({ session = true })
    harness.run_lua('vim.cmd("silent! %bwipeout!")')
    local file_path = harness.temporary_directory .. '/kept.txt'
    vim.fn.writefile({ 'on disk' }, file_path)
    harness.run_lua('vim.cmd.edit(...)', file_path)
    harness.wait_until_idle()
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, {"changed, not saved"})')
    harness.press_keys('<C-n>')
    harness.type_text('scratch note')
    pcall(harness.run_lua, 'require("notebashpp.file_commands").exit()')
    vim.wait(300)
    harness.start_editor({ session = true })
    harness.wait_until_idle(300)
    local restored_documents = harness.run_lua([[local document_texts = {}
        for _, buffer in ipairs(require("notebashpp.document_tabs").sync()) do
            document_texts[#document_texts + 1] = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "|") .. (vim.bo[buffer].modified and "*" or "")
        end
        return document_texts]])
    expect_equal(true, vim.tbl_contains(restored_documents, 'changed, not saved*'), 'file with changes: ' .. vim.inspect(restored_documents))
    expect_equal(true, vim.tbl_contains(restored_documents, 'scratch note*') or vim.tbl_contains(restored_documents, 'scratch note'), 'new doc')
    expect_equal({ 'on disk' }, vim.fn.readfile(file_path), 'disk untouched')
    harness.stop_editor()
    harness.start_editor()
end)
test_case('snapshots are private, keep a trailing \\r, and warn when the file changed since', function()
    harness.stop_editor()
    harness.start_editor({ session = true })
    harness.run_lua('vim.cmd("silent! %bwipeout!")')
    local file_path = harness.temporary_directory .. '/kept-cr.txt'
    vim.fn.writefile({ 'on disk' }, file_path)
    harness.run_lua('vim.cmd.edit(...)', file_path)
    harness.wait_until_idle()
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, {"ends in cr\\r", "plain"})')
    pcall(harness.run_lua, 'require("notebashpp.file_commands").exit()')
    vim.wait(300)
    local session_directory = harness.temporary_directory .. '/data/notebashpp-test/session'
    expect_equal('rwx------', vim.fn.getfperm(session_directory), 'session folder')
    expect_equal('rwx------', vim.fn.getfperm(session_directory .. '/backup'), 'backup folder')
    expect_equal('rw-------', vim.fn.getfperm(session_directory .. '/session.json'), 'session.json')
    for _, backup_name in ipairs(vim.fn.readdir(session_directory .. '/backup')) do
        expect_equal('rw-------', vim.fn.getfperm(session_directory .. '/backup/' .. backup_name), backup_name)
    end
    vim.uv.fs_utime(file_path, os.time() + 60, os.time() + 60)
    harness.start_editor({ session = true })
    harness.wait_until_idle(300)
    expect_equal({ 'ends in cr\r', 'plain' }, harness.run_lua('return vim.api.nvim_buf_get_lines(vim.fn.bufnr(...), 0, -1, false)', file_path))
    local message_log = harness.run_lua('return table.concat(vim.fn.readfile(require("notebashpp.messages").log_path()), "\\n")')
    expect_equal(true, message_log:find('WARN Changed on disk after your unsaved edits', 1, true) ~= nil, 'warning logged: ' .. message_log)
    local notification_texts = table.concat(harness.run_lua('return require("notebashpp.messages").visible_texts()'), '\n')
    expect_equal(true, notification_texts:find('Changed on disk after your unsaved edits', 1, true) ~= nil, 'warning shown: ' .. notification_texts)
    local saved = harness.run_lua(
        [[local real_confirm = vim.fn.confirm
        vim.fn.confirm = function() return 2 end
        vim.cmd.buffer(vim.fn.bufnr(...))
        local result = require("notebashpp.file_commands").save()
        vim.fn.confirm = real_confirm
        return result]],
        file_path
    )
    expect_equal(false, saved, 'save asked and was refused')
    expect_equal({ 'on disk' }, vim.fn.readfile(file_path), 'newer file kept')
    harness.stop_editor()
    harness.start_editor()
end)

-- shared restore helpers: start without a session, set up documents &
-- windows, leave cleanly or get killed, then compare what comes back. i'd
-- love this level of accountability from my life.
local session_directory = harness.temporary_directory .. '/data/notebashpp-test/session'

local function start_session_editor_without_session()
    harness.stop_editor()
    vim.fn.delete(session_directory, 'rf')
    harness.start_editor({ session = true })
    harness.run_lua('vim.cmd("silent! %bwipeout!")')
    harness.wait_until_idle()
end

-- leave by alt+f4 or sigkill (a crash: no exit code runs), then restart with
-- the session. even my documents refuse to rest in peace.
local function restart_session_editor(how_to_leave)
    if how_to_leave == 'crash' then
        vim.uv.kill(harness.run_lua('return vim.fn.getpid()'), 'sigkill')
        vim.wait(200)
    else
        pcall(harness.run_lua, 'require("notebashpp.file_commands").exit()')
        vim.wait(300)
    end
    harness.stop_editor()
    harness.start_editor({ session = true })
    harness.wait_until_idle(500)
end

-- 40 blocks, each a heading & five indented lines: indent folds at lines 2 to
-- 6, 8 to 12 and so on. i have built a filing cabinet for nothing.
local function write_folding_file(file_path, extra_lines_at_top)
    local lines = vim.deepcopy(extra_lines_at_top or {})
    for block = 1, 40 do
        lines[#lines + 1] = 'block ' .. block
        for item = 1, 5 do
            lines[#lines + 1] = '    item ' .. block .. '.' .. item
        end
    end
    vim.fn.writefile(lines, file_path)
end

-- describe every window in the tab page's layout tree: file name, size,
-- caret, top line, visible closed folds & which window is current. basically
-- a census of places i've failed to finish anything.
local function describe_windows()
    return harness.run_lua([[
        local function describe(layout_node)
            if layout_node[1] == 'leaf' then
                local window = layout_node[2]
                local view = vim.api.nvim_win_call(window, vim.fn.winsaveview)
                local closed_folds = {}
                vim.api.nvim_win_call(window, function()
                    for line_number = 1, vim.fn.line('$') do
                        if vim.fn.foldclosed(line_number) == line_number then
                            closed_folds[#closed_folds + 1] = { line_number, vim.fn.foldclosedend(line_number) }
                        end
                    end
                end)
                return {
                    name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(window)), ':t'),
                    width = vim.api.nvim_win_get_width(window),
                    height = vim.api.nvim_win_get_height(window),
                    caret = { view.lnum, view.col },
                    topline = view.topline,
                    closed_folds = closed_folds,
                    current = window == vim.api.nvim_get_current_win(),
                }
            end
            local children = {}
            for _, child_node in ipairs(layout_node[2]) do
                children[#children + 1] = describe(child_node)
            end
            return { layout_node[1], children }
        end
        return describe(vim.fn.winlayout())
    ]])
end

-- show the file in the current window, close folds at the given lines, then
-- put `top_line` at the top & the caret on `caret`. i want control over
-- something, even if it's this shit.
local function set_window_view(caret, top_line, fold_lines)
    harness.run_lua(
        [[local caret, top_line, fold_lines = ...
        for _, fold_line in ipairs(fold_lines) do
            vim.api.nvim_cmd({ cmd = 'foldclose', range = { fold_line } }, {})
        end
        vim.fn.winrestview({ lnum = caret[1], col = caret[2], topline = top_line })]],
        caret,
        top_line,
        fold_lines
    )
end

test_case('split windows, scroll and folds come back after a restart', function()
    start_session_editor_without_session()
    local folds_file, other_file = harness.temporary_directory .. '/session-folds.txt', harness.temporary_directory .. '/session-other.txt'
    local hidden_file = harness.temporary_directory .. '/session-hidden.txt'
    write_folding_file(folds_file)
    local other_lines = {}
    for line_number = 1, 100 do
        other_lines[line_number] = 'other line ' .. line_number
    end
    vim.fn.writefile(other_lines, other_file)
    vim.fn.writefile(other_lines, hidden_file)
    -- a document no window shows keeps its scroll position too. unlike my
    -- hopes.
    harness.run_lua('vim.cmd.edit(...)', hidden_file)
    set_window_view({ 60, 3 }, 55, {})
    -- left: folds file with two closed folds. right: other file above the
    -- folds file again, with one fold open & a different scroll position.
    -- same unfinished work, more windows. absolutely my mistake.
    harness.run_lua('vim.cmd.edit(...)', folds_file)
    set_window_view({ 50, 2 }, 40, { 14, 38 })
    harness.run_lua('vim.cmd("vsplit"); vim.cmd.edit(...)', other_file)
    set_window_view({ 35, 0 }, 30, {})
    harness.run_lua('vim.cmd("split"); vim.api.nvim_set_current_buf(vim.fn.bufnr(...))', folds_file)
    harness.run_lua('vim.api.nvim_cmd({ cmd = "foldopen", range = { 14 } }, {})')
    set_window_view({ 200, 6 }, 190, {})
    harness.run_lua('vim.api.nvim_win_set_width(vim.fn.win_getid(1), 30); vim.api.nvim_win_set_height(0, 8)')
    harness.wait_until_idle()
    local windows_before = describe_windows()
    expect_equal('row', windows_before[1], 'set up as a row')
    expect_equal({ { 38, 42 } }, windows_before[2][2][2][2].closed_folds, 'set up with one fold open below')
    restart_session_editor('exit')
    expect_equal(windows_before, describe_windows(), 'windows')
    expect_equal('i', harness.current_mode(), 'typing')
    expect_equal(
        { 60, 3, 55 },
        harness.run_lua(
            'vim.api.nvim_set_current_buf(vim.fn.bufnr(...)); local view = vim.fn.winsaveview(); return { view.lnum, view.col, view.topline }',
            hidden_file
        ),
        'document without a window'
    )
    harness.run_lua('vim.cmd("buffer #")')
end)
test_case('a closed fold is found again after lines were added above it', function()
    local folds_file = harness.temporary_directory .. '/session-folds.txt'
    pcall(harness.run_lua, 'require("notebashpp.file_commands").exit()')
    vim.wait(300)
    harness.stop_editor()
    write_folding_file(folds_file, { 'new line 1', 'new line 2', 'new line 3' })
    harness.start_editor({ session = true })
    harness.wait_until_idle(500)
    local left_window = describe_windows()[2][1]
    expect_equal('session-folds.txt', left_window.name, 'left window')
    expect_equal({ { 17, 21 }, { 41, 45 } }, left_window.closed_folds, 'folds moved down three lines')
end)
test_case('a selection comes back selected; typing replaces it', function()
    start_session_editor_without_session()
    harness.set_buffer_lines({ 'hello world' })
    harness.run_lua('vim.cmd("startinsert")')
    harness.set_cursor_position(1, 0)
    harness.press_keys('<S-Right><S-Right><S-Right><S-Right><S-Right>')
    expect_equal('hello', harness.selected_text(), 'selected before')
    restart_session_editor('exit')
    expect_equal('hello', harness.selected_text(), 'selected after')
    harness.type_text('X')
    expect_equal('X world', harness.buffer_text())
end)
test_case('a column selection comes back as a column selection', function()
    start_session_editor_without_session()
    harness.set_buffer_lines({ 'abcd', 'efgh', 'ij' })
    harness.run_lua('vim.cmd("startinsert")')
    harness.set_cursor_position(1, 1)
    harness.press_keys('<M-S-Down><M-S-Down><M-S-Right><M-S-Right><M-S-Right>')
    restart_session_editor('exit')
    expect_equal({ anchor = { 1, 1 }, caret = { 3, 4 } }, harness.run_lua('return require("notebashpp.column_mode").corners()'), 'rectangle')
    harness.press_keys('<C-c>')
    expect_equal('bcd\nfgh\nj', harness.clipboard_text())
end)
test_case('after a crash the work of a few seconds ago comes back', function()
    start_session_editor_without_session()
    local folds_file = harness.temporary_directory .. '/session-crash.txt'
    write_folding_file(folds_file)
    harness.run_lua('vim.cmd.edit(...)', folds_file)
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, 1, false, {"changed before the crash"})')
    set_window_view({ 100, 4 }, 80, { 92 })
    harness.press_keys('<C-n>')
    harness.type_text('typed before the crash')
    harness.run_lua('vim.cmd("vsplit"); vim.api.nvim_set_current_buf(vim.fn.bufnr(...))', folds_file)
    harness.wait_until_idle()
    local windows_before = describe_windows()
    -- save waits for a 1 s pause in changes. even this crap needs peace.
    vim.wait(2000)
    harness.wait_until_idle()
    restart_session_editor('crash')
    expect_equal(windows_before, describe_windows(), 'windows')
    local restored_documents = harness.run_lua([[local document_texts = {}
        for _, buffer in ipairs(require("notebashpp.document_tabs").sync()) do
            document_texts[#document_texts + 1] = vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1]
        end
        return document_texts]])
    expect_equal(true, vim.tbl_contains(restored_documents, 'changed before the crash'), 'file changes: ' .. vim.inspect(restored_documents))
    expect_equal(true, vim.tbl_contains(restored_documents, 'typed before the crash'), 'new document: ' .. vim.inspect(restored_documents))
end)
test_case('saving writes nothing when nothing changed', function()
    -- each write renames a new file over the old one, giving it a new inode.
    -- i've paid for worse fresh starts.
    local function session_file_inode()
        return (vim.uv.fs_stat(session_directory .. '/session.json') or {}).ino
    end
    harness.run_lua('require("notebashpp.session").save()')
    local first_inode = session_file_inode()
    harness.run_lua('require("notebashpp.session").save()')
    expect_equal(first_inode, session_file_inode(), 'same file after an idle save')
    harness.run_lua('vim.api.nvim_win_set_cursor(0, { 3, 0 }); require("notebashpp.session").save()')
    expect_equal(true, first_inode ~= session_file_inode(), 'rewritten after the caret moved')
end)
test_case('session files of formats 1 and 2 still load', function()
    local old_file = harness.temporary_directory .. '/session-old-format.txt'
    vim.fn.writefile({ 'one', 'two', 'three words here' }, old_file)
    for _, saved_format in ipairs({ 1, 2 }) do
        harness.stop_editor()
        vim.fn.delete(session_directory, 'rf')
        vim.fn.mkdir(session_directory .. '/backup', 'p')
        -- format 1 had no format number; backups were text lines. my legacy,
        -- shit.
        if saved_format == 1 then
            vim.fn.writefile({ 'old note' }, session_directory .. '/backup/new_1_7.txt')
        else
            vim.fn.writefile({ 'old note' }, session_directory .. '/backup/new_1_7.txt', 'b')
        end
        local documents = { { path = old_file, cursor = { 3, 6 }, current = true }, { new = 1, backup = 'new_1_7.txt', ff = 'unix' } }
        vim.fn.writefile({ vim.json.encode({ format = saved_format == 2 and 2 or nil, docs = documents }) }, session_directory .. '/session.json')
        harness.start_editor({ session = true })
        harness.wait_until_idle(300)
        expect_equal(old_file, harness.run_lua('return vim.api.nvim_buf_get_name(0)'), 'current document, format ' .. saved_format)
        expect_equal({ 3, 6 }, harness.cursor_position(), 'caret, format ' .. saved_format)
        expect_equal(
            { 'old note' },
            harness.run_lua('return vim.api.nvim_buf_get_lines(require("notebashpp.document_tabs").sync()[2], 0, -1, false)'),
            'backup, format ' .. saved_format
        )
    end
    harness.stop_editor()
    vim.fn.delete(session_directory, 'rf')
    harness.start_editor()
end)
test_case('a special document view saves and restores its own state', function()
    start_session_editor_without_session()
    local source_file = harness.temporary_directory .. '/session-special.txt'
    vim.fn.writefile({ 'a,b', '1,2' }, source_file)
    -- stand-in spreadsheet view: keeps its own zoom number & rebuilds the
    -- buffer from it. finally i can make my failures look bigger.
    local register_test_view = 'autocmd VimEnter * ++once lua require("notebashpp.session").register_special_view("test_view", {'
        .. ' save = function(buffer) return { zoom = vim.b[buffer].test_zoom } end,'
        .. ' restore = function(state, document) local buffer = vim.api.nvim_create_buf(true, false);'
        .. ' vim.api.nvim_buf_set_name(buffer, document.path); vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "zoom " .. state.zoom });'
        .. ' vim.bo[buffer].modified = false; vim.b[buffer].notebashpp_special_view = "test_view"; vim.b[buffer].test_zoom = state.zoom; return buffer end })'
    harness.stop_editor()
    harness.start_editor({ session = true, extra_arguments = { '--cmd', register_test_view } })
    harness.run_lua('vim.cmd.edit(...); vim.b.notebashpp_special_view = "test_view"; vim.b.test_zoom = 3', source_file)
    harness.wait_until_idle()
    pcall(harness.run_lua, 'require("notebashpp.file_commands").exit()')
    vim.wait(300)
    harness.start_editor({ session = true, extra_arguments = { '--cmd', register_test_view } })
    harness.wait_until_idle(300)
    expect_equal(
        { source_file, { 'zoom 3' }, 'test_view' },
        harness.run_lua('return { vim.api.nvim_buf_get_name(0), vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.b.notebashpp_special_view }')
    )
    harness.stop_editor()
    vim.fn.delete(session_directory, 'rf')
    harness.start_editor()
end)

io.write('user.lua\n')
test_case('user.lua changes Ctrl+D, Ctrl+L, keys, and adds commands', function()
    harness.stop_editor()
    harness.start_editor({ user_file = harness.project_root .. '/tests/user_settings_fixture.lua' })
    start_with_lines({ 'ab', 'cd', 'ef' }, 1, 1)
    harness.press_keys('<S-Right>')
    harness.press_keys('<C-d>')
    expect_equal('ab\nab\ncd\nef', harness.buffer_text(), 'Ctrl+D duplicates whole lines')
    start_with_lines({ 'one', 'two', 'three', 'four' }, 2, 1)
    harness.set_clipboard_text('keep')
    harness.press_keys('<S-Down>')
    harness.press_keys('<C-l>')
    expect_equal('one\nfour', harness.buffer_text(), 'Ctrl+L deletes the selected lines')
    expect_equal('keep', harness.clipboard_text(), 'clipboard untouched')
    harness.press_keys('<S-F10>')
    expect_equal(true, harness.run_lua('return vim.wo.rightleft'), 'a command given a new key')
    harness.run_lua('vim.wo.rightleft = false')
    start_with_lines({ 'quiet' }, 1, 0)
    harness.press_keys('<C-M-k1>')
    expect_equal('QUIET', harness.buffer_text(), 'a command from user.lua')
    harness.press_keys('<M-m>')
    local menu_text = harness.run_lua('return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\\n")')
    expect_equal(true, menu_text:find('Shout the Current Line', 1, true) ~= nil, 'listed in the Macro menu')
    harness.press_keys('<Esc>')
    harness.stop_editor()
    harness.start_editor()
end)

io.write('live reload\n')
test_case('a reload keeps tabs, Find history, macro, zoom and View toggles', function()
    start_with_lines({ 'one', 'two' }, 1, 0)
    harness.run_lua([[
        require("notebashpp.find_and_replace").state.hist.find = { "kept" }
        require("notebashpp.macros").recorded = "abc"
        require("notebashpp.appearance").zoom = 3
        vim.wo.wrap = false
        vim.keymap.set("i", "<C-M-F12>", "gone")
        _G.old_edit = require("notebashpp.editing_commands")
    ]])
    local tab_order = harness.run_lua('return require("notebashpp.document_tabs").order')
    expect_equal(true, harness.run_lua('return require("notebashpp.live_code_reload").reload({ "editing_commands.lua" })'), 'reloaded')
    harness.wait_until_idle()
    expect_equal(false, harness.run_lua('return _G.old_edit == require("notebashpp.editing_commands")'), 'new code loaded')
    expect_equal({ 'kept' }, harness.run_lua('return require("notebashpp.find_and_replace").state.hist.find'))
    expect_equal('abc', harness.run_lua('return require("notebashpp.macros").recorded'))
    expect_equal(3, harness.run_lua('return require("notebashpp.appearance").zoom'))
    expect_equal(false, harness.run_lua('return vim.wo.wrap'), 'View toggle kept')
    expect_equal(tab_order, harness.run_lua('return require("notebashpp.document_tabs").order'))
    expect_equal(true, harness.run_lua('return vim.fn.maparg("<C-M-F12>", "i") ~= "gone"'), 'stale mapping cleared')
    expect_equal('i', harness.current_mode())
    harness.press_keys('<C-d>')
    expect_equal('one\none\ntwo', harness.buffer_text(), 'keys work after reload')
    harness.run_lua('require("notebashpp.appearance").zoom = -2; vim.wo.wrap = true')
end)
test_case('a saved file reloads by itself; a broken one is refused', function()
    harness.stop_editor()
    local code_copy = harness.temporary_directory .. '/code'
    vim.fn.system({ 'cp', '-r', harness.project_root, code_copy })
    harness.start_editor({ code_root = code_copy })
    harness.run_lua('require("notebashpp.live_code_reload").watch()')
    start_with_lines({ 'one', 'two' }, 2, 0)
    local keybindings_file = code_copy .. '/lua/notebashpp/keybindings.lua'
    local keybindings_source = table.concat(vim.fn.readfile(keybindings_file), '\n')
    local changed_source = keybindings_source:gsub("'Transpose Current and Previous Lines', { '<C%-t>' }", "'Transpose Current and Previous Lines', {}")
    vim.fn.writefile(vim.split(changed_source, '\n'), keybindings_file)
    vim.wait(3000, function()
        return harness.run_lua('return require("notebashpp.live_code_reload").count') == 1
    end, 50)
    expect_equal(1, harness.run_lua('return require("notebashpp.live_code_reload").count'), 'reloaded once')
    harness.wait_until_idle()
    harness.press_keys('<C-t>')
    expect_equal('one\ntwo', harness.buffer_text(), 'Ctrl+T taken out of keybindings.lua no longer swaps')
    harness.press_keys('<C-d>')
    expect_equal('one\ntwo\ntwo', harness.buffer_text())
    local editing_commands_file = code_copy .. '/lua/notebashpp/editing_commands.lua'
    vim.fn.writefile({ 'local M = {', 'return M' }, editing_commands_file)
    vim.wait(1500)
    expect_equal(1, harness.run_lua('return require("notebashpp.live_code_reload").count'), 'broken file not loaded')
    harness.press_keys('<C-d>')
    expect_equal('one\ntwo\ntwo\ntwo', harness.buffer_text(), 'old code still runs')
    harness.stop_editor()
    vim.fn.delete(code_copy, 'rf')
    harness.start_editor()
end)

test_case('Rename asks before replacing a file and keeps unsaved edits unsaved', function()
    local old_path = harness.temporary_directory .. '/rename-old.txt'
    local taken_path = harness.temporary_directory .. '/rename-taken.txt'
    local new_path = harness.temporary_directory .. '/rename-new.txt'
    vim.fn.writefile({ 'old' }, old_path)
    vim.fn.writefile({ 'taken' }, taken_path)
    vim.fn.delete(new_path)
    harness.run_lua('vim.cmd.edit(...)', old_path)
    harness.wait_until_idle()
    local rename_to = [[local helpers = require("notebashpp.helpers")
        local real_ask, real_confirm = helpers.ask, vim.fn.confirm
        local target, answer = ...
        helpers.ask = function() return target end
        vim.fn.confirm = function() return answer end
        require("notebashpp.file_commands").rename()
        helpers.ask, vim.fn.confirm = real_ask, real_confirm]]
    harness.run_lua(rename_to, taken_path, 2)
    expect_equal({ 'taken' }, vim.fn.readfile(taken_path), 'existing file kept')
    expect_equal({ 'old' }, vim.fn.readfile(old_path), 'old file kept')
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, {"edited"})')
    harness.run_lua(rename_to, new_path, 1)
    expect_equal(0, vim.fn.filereadable(old_path), 'old name gone')
    expect_equal({ 'old' }, vim.fn.readfile(new_path), 'renamed, edits not written yet')
    expect_equal(true, harness.run_lua('return vim.bo.modified'), 'still unsaved')
    expect_equal(true, harness.run_lua('return require("notebashpp.file_commands").save()'), 'save worked')
    expect_equal({ 'edited' }, vim.fn.readfile(new_path), 'saved under the new name')
    harness.run_lua('vim.cmd("enew!")')
end)

io.write('view settings\n')
test_case('word wrap stays on in every document, new ones and after a restart', function()
    local first_file, second_file = harness.temporary_directory .. '/wrap-a.txt', harness.temporary_directory .. '/wrap-b.txt'
    vim.fn.writefile({ 'a' }, first_file)
    vim.fn.writefile({ 'b' }, second_file)
    harness.run_lua('vim.cmd.edit(...)', first_file)
    harness.run_lua('vim.cmd.edit(...)', second_file)
    harness.wait_until_idle()
    local wrap_was_on = harness.run_lua('return vim.wo.wrap')
    harness.run_lua('require("notebashpp.keybindings").by_id.word_wrap.fn()')
    local wrap_now = not wrap_was_on
    expect_equal(wrap_now, harness.run_lua('return vim.wo.wrap'), 'toggled here')
    harness.press_keys('<C-PageUp>')
    expect_equal(wrap_now, harness.run_lua('return vim.wo.wrap'), 'the other document')
    harness.press_keys('<C-n>')
    expect_equal(wrap_now, harness.run_lua('return vim.wo.wrap'), 'a new document')
    harness.stop_editor()
    harness.start_editor()
    expect_equal(wrap_now, harness.run_lua('return vim.wo.wrap'), 'after a restart')
    harness.run_lua('require("notebashpp.view_settings").set("word_wrap", ...)', wrap_was_on)
    harness.run_lua('vim.cmd("enew!")')
end)
test_case('Compare keeps word wrap on', function()
    local first_file, second_file = harness.temporary_directory .. '/cmp-wrap-a.txt', harness.temporary_directory .. '/cmp-wrap-b.txt'
    vim.fn.writefile({ 'one', 'two' }, first_file)
    vim.fn.writefile({ 'one', 'three' }, second_file)
    harness.run_lua('require("notebashpp.view_settings").set("word_wrap", true)')
    harness.run_lua('vim.cmd.edit(...)', first_file)
    harness.run_lua('vim.cmd.edit(...)', second_file)
    harness.wait_until_idle()
    harness.run_lua('local compare = require("notebashpp.compare_documents"); compare.set_first(); vim.cmd("bprevious"); compare.compare()')
    harness.wait_until_idle()
    expect_equal(
        { true, true },
        harness.run_lua([[local wraps = {}
        for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_get_config(window).relative == '' then wraps[#wraps + 1] = vim.wo[window].wrap end
        end
        return wraps]])
    )
    harness.run_lua('require("notebashpp.compare_documents").clear(); vim.cmd("enew!")')
end)
test_case('zoom moves one point per press, from 4 to 72 points', function()
    harness.run_lua('vim.g.neovide = true; local appearance = require("notebashpp.appearance"); appearance.zoom = 0; appearance.apply_font()')
    local function font_size()
        return tonumber(harness.run_lua('return vim.o.guifont'):match(':h(%d+)'))
    end
    local start_size = font_size()
    harness.press_keys('<C-=>')
    expect_equal(start_size + 1, font_size(), 'ctrl+=')
    harness.press_keys('<C-->')
    harness.press_keys('<C-->')
    expect_equal(start_size - 1, font_size(), 'ctrl+-')
    harness.run_lua('for _ = 1, 100 do require("notebashpp.appearance").zoom_by(-1) end')
    expect_equal(4, font_size(), 'smallest')
    harness.run_lua('for _ = 1, 100 do require("notebashpp.appearance").zoom_by(1) end')
    expect_equal(72, font_size(), 'largest')
    harness.press_keys('<C-kDivide>')
    expect_equal(start_size, font_size(), 'restore')
    harness.run_lua('vim.g.neovide = nil')
end)

io.write('plugins and extras\n')
test_case('the status bar counts words', function()
    start_with_lines({ 'one two three', 'four' }, 1, 0)
    local status_line = harness.run_lua('vim.o.columns = 200; return require("notebashpp.status_bar").render()')
    harness.run_lua('vim.o.columns = 80')
    expect_equal(true, status_line:find('words : 4', 1, true) ~= nil, status_line)
end)
test_case('json and markdown show every character, nothing concealed', function()
    local json_path = harness.temporary_directory .. '/quotes.json'
    vim.fn.writefile({ '{', '  "team": "Platform"', '}' }, json_path)
    harness.run_lua('require("notebashpp.file_commands").open_path(...)', json_path)
    harness.wait_until_idle()
    expect_equal(0, harness.run_lua('return vim.fn.synconcealed(2, 3)[1]'), 'json quote concealed')
    local markdown_conceals = harness.run_lua([[local count = 0
        for _, language in ipairs({ 'markdown', 'markdown_inline' }) do
            local query = vim.treesitter.query.get(language, 'highlights')
            for _, directives in pairs(query and query.info.patterns or {}) do
                for _, directive in ipairs(directives) do
                    if directive[1] == 'set!' and tostring(directive[2]):match('^conceal') then
                        count = count + 1
                    end
                end
            end
        end
        return count]])
    expect_equal(0, markdown_conceals, 'markdown conceal directives')
    harness.run_lua('vim.cmd("enew!"); vim.cmd("silent! bwipeout! " .. vim.fn.bufnr(...))', json_path)
end)
test_case('the status bar length counts the bytes the file will have', function()
    start_with_lines({ 'one two three', 'four' }, 1, 0)
    local function length(settings)
        return harness.run_lua(settings .. '; vim.o.columns = 200; return require("notebashpp.status_bar").render():match("length : (%d+)")')
    end
    expect_equal('18', length('vim.bo.fileformat = "unix"; vim.bo.endofline = false'), 'unix, no last line end')
    expect_equal('19', length('vim.bo.fileformat = "unix"; vim.bo.endofline = true'), 'unix, last line end')
    expect_equal('19', length('vim.bo.fileformat = "dos"; vim.bo.endofline = false'), 'dos, no last line end')
    expect_equal('21', length('vim.bo.fileformat = "dos"; vim.bo.endofline = true'), 'dos, last line end')
    harness.run_lua('vim.o.columns = 80')
end)
test_case('dark mode repaints and is remembered', function()
    harness.run_lua('require("notebashpp.keybindings").by_id.dark_mode.fn()')
    expect_equal('dark', harness.run_lua('return vim.o.background'))
    expect_equal(0x1E1E1E, harness.run_lua('return vim.api.nvim_get_hl(0, { name = "Normal" }).bg'))
    harness.stop_editor()
    harness.start_editor()
    expect_equal('dark', harness.run_lua('return vim.o.background'), 'after a restart')
    harness.run_lua('require("notebashpp.keybindings").by_id.dark_mode.fn()')
    expect_equal(0xFFFFFF, harness.run_lua('return vim.api.nvim_get_hl(0, { name = "Normal" }).bg'))
end)
test_case('spell check finds a misspelling, suggests, and replaces it', function()
    start_with_lines({ 'this sentense has a mistake' }, 1, 0)
    harness.run_lua('require("notebashpp.view_settings").set("spell_check", true)')
    harness.run_lua('require("notebashpp.spell_check").jump(1)')
    -- the selection is made with fed keys; let them run before reading it.
    harness.wait_until_idle()
    expect_equal('sentense', harness.selected_text())
    harness.press_keys('<Esc>')
    harness.set_cursor_position(1, 7)
    local suggestions = harness.run_lua([[require("notebashpp.spell_check").prepare_popup()
        return vim.fn.menu_get("PopUp")[1].submenus[1].name]])
    expect_equal('sentence', suggestions)
    harness.run_lua('require("notebashpp.spell_check").use_suggestion(1)')
    expect_equal('this sentence has a mistake', harness.buffer_text())
    harness.run_lua('require("notebashpp.view_settings").set("spell_check", false)')
end)
test_case('JSON format keeps key order and refuses invalid JSON', function()
    start_with_lines({ '{"b":1,"a":[1,2.50],"e":{}}' }, 1, 0)
    harness.run_lua('vim.bo.expandtab = true; vim.bo.shiftwidth = 2; require("notebashpp.json_and_xml_tools").format_json()')
    expect_equal('{\n  "b": 1,\n  "a": [\n    1,\n    2.50\n  ],\n  "e": {}\n}', harness.buffer_text())
    harness.run_lua('require("notebashpp.json_and_xml_tools").minify_json()')
    expect_equal('{"b":1,"a":[1,2.50],"e":{}}', harness.buffer_text())
    start_with_lines({ '{"a": 1,,}' }, 1, 0)
    harness.run_lua('require("notebashpp.json_and_xml_tools").format_json()')
    expect_equal('{"a": 1,,}', harness.buffer_text(), 'invalid json untouched')
end)
test_case('XML pretty print, linearize and syntax check', function()
    start_with_lines({ '<r a="1>2"><x>  two  </x><y><z/></y></r>' }, 1, 0)
    harness.run_lua('vim.bo.expandtab = true; vim.bo.shiftwidth = 2; require("notebashpp.json_and_xml_tools").format_xml()')
    expect_equal('<r a="1>2">\n  <x>  two  </x>\n  <y>\n    <z/>\n  </y>\n</r>', harness.buffer_text())
    harness.run_lua('require("notebashpp.json_and_xml_tools").linearize_xml()')
    expect_equal('<r a="1>2"><x>  two  </x><y><z/></y></r>', harness.buffer_text())
    start_with_lines({ '<r>', '<a>1</b>', '</r>' }, 1, 0)
    harness.run_lua('vim.cmd("messages clear"); require("notebashpp.json_and_xml_tools").format_xml()')
    expect_equal('<r>\n<a>1</b>\n</r>', harness.buffer_text(), 'broken xml untouched')
end)
test_case('Align by Equals lines up assignments and skips comparisons', function()
    start_with_lines({ 'width = 10', 'height_max += 4', 'if a == b then' }, 1, 0)
    harness.run_lua('require("notebashpp.code_alignment").align("equals")')
    expect_equal('width       = 10\nheight_max += 4\nif a == b then', harness.buffer_text())
end)
test_case('View in HEX shows the bytes and writes edits back', function()
    local hex_file = harness.temporary_directory .. '/hex.txt'
    local file_handle = assert(io.open(hex_file, 'wb'), 'temp file')
    file_handle:write('Hello\r\n')
    file_handle:close()
    harness.run_lua('vim.cmd.edit(...)', hex_file)
    harness.wait_until_idle()
    harness.run_lua('require("notebashpp.hex_view").toggle()')
    expect_equal('00000000: 4865 6c6c 6f0d 0a                        Hello..', harness.buffer_text())
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, 1, false, { "00000000: 4a65 6c6c 6f0d 0a" })')
    harness.run_lua('require("notebashpp.file_commands").save()')
    harness.wait_until_idle()
    local read_handle = assert(io.open(hex_file, 'rb'), 'read back')
    expect_equal('Jello\r\n', read_handle:read('*a'))
    read_handle:close()
    harness.run_lua('require("notebashpp.hex_view").toggle()')
    expect_equal('Jello', harness.buffer_text())
    harness.run_lua('vim.cmd("enew!")')
end)

io.write('syntax selection\n')
-- expand until selection stops growing; return each selected text. ambition
-- dies.
local function expand_steps(maximum_steps)
    local steps = {}
    for _ = 1, maximum_steps do
        harness.press_keys('<C-M-Up>')
        local selected = harness.selected_text()
        if selected == steps[#steps] then
            break
        end
        steps[#steps + 1] = selected
    end
    return steps
end
test_case('Ctrl+Alt+Up grows the selection along the Lua syntax tree, Ctrl+Alt+Down shrinks it', function()
    start_with_lines({ 'local function greet(name)', "    return 'hi ' .. name", 'end' }, 2, 21)
    harness.run_lua('vim.bo.filetype = "lua"')
    harness.run_lua('vim.cmd("startinsert")')
    harness.wait_until_idle()
    harness.set_cursor_position(2, 21)
    local steps = expand_steps(8)
    expect_equal('name', steps[1], 'first step')
    expect_equal("'hi ' .. name", steps[2], 'second step')
    expect_equal("return 'hi ' .. name", steps[3], 'third step')
    expect_equal(harness.buffer_text(), steps[#steps], 'last step')
    expect_equal('s', harness.current_mode(), 'a normal selection')
    harness.press_keys('<C-M-Down>')
    expect_equal(steps[#steps - 1], harness.selected_text(), 'one step back')
    for _ = 1, #steps - 2 do
        harness.press_keys('<C-M-Down>')
    end
    expect_equal('name', harness.selected_text(), 'back to the word')
    harness.press_keys('<C-M-Down>')
    expect_equal('', harness.selected_text(), 'back to the caret')
    expect_equal({ 2, 21 }, harness.cursor_position(), 'caret where it was')
    harness.run_lua('vim.bo.filetype = ""')
end)
test_case('an expanded selection is replaced by typing and continued by Shift+arrows', function()
    start_with_lines({ 'one two three' }, 1, 5)
    harness.press_keys('<C-M-Up>')
    expect_equal('two', harness.selected_text())
    harness.press_keys('<S-Right>')
    expect_equal('two ', harness.selected_text(), 'Shift+Right continues it')
    harness.type_text('X')
    expect_equal('one Xthree', harness.buffer_text(), 'typing replaces it')
end)
test_case('without a parser the selection grows by word, quotes, brackets, line, paragraph, document', function()
    start_with_lines({ 'first line', 'call(alpha, "beta gamma")', 'last line', '', 'next paragraph' }, 2, 20)
    local steps = expand_steps(12)
    expect_equal({
        'gamma',
        'beta gamma',
        '"beta gamma"',
        'alpha, "beta gamma"',
        '(alpha, "beta gamma")',
        'call(alpha, "beta gamma")',
        'first line\ncall(alpha, "beta gamma")\nlast line',
        harness.buffer_text(),
    }, steps)
    harness.press_keys('<C-M-Down>')
    harness.press_keys('<C-M-Down>')
    expect_equal('call(alpha, "beta gamma")', harness.selected_text(), 'shrink steps back')
    harness.press_keys('<Right>')
end)
test_case('brackets over several lines and the Markdown parser', function()
    start_with_lines({ 'x = {', '  a = (1 + 2),', '}' }, 2, 8)
    harness.press_keys('<C-M-Up>')
    harness.press_keys('<C-M-Up>')
    expect_equal('1 + 2', harness.selected_text(), 'inside the parentheses')
    local bracket_steps = expand_steps(8)
    expect_equal('(1 + 2)', bracket_steps[1], 'the parentheses')
    expect_equal(true, vim.tbl_contains(bracket_steps, '{\n  a = (1 + 2),\n}'), 'the braces across lines: ' .. vim.inspect(bracket_steps))
    start_with_lines({ '# Title', '', 'Some *bold* text here.', 'More text.' }, 3, 7)
    harness.run_lua('vim.bo.filetype = "markdown"')
    harness.run_lua('vim.cmd("startinsert")')
    harness.wait_until_idle()
    harness.set_cursor_position(3, 7)
    local steps = expand_steps(8)
    expect_equal('bold', steps[1], 'word')
    expect_equal('*bold*', steps[2], 'emphasis node')
    expect_equal(true, vim.tbl_contains(steps, 'Some *bold* text here.\nMore text.'), 'paragraph node: ' .. vim.inspect(steps))
    expect_equal(harness.buffer_text(), steps[#steps], 'whole document')
    harness.run_lua('vim.bo.filetype = ""')
    harness.press_keys('<Right>')
end)
test_case('expand and shrink are in the Edit menu', function()
    harness.press_keys('<M-e>')
    local menu_text = harness.run_lua('return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\\n")')
    harness.press_keys('<Esc>')
    expect_equal(true, menu_text:find('Expand Selection%s+Ctrl%+Alt%+Up') ~= nil, menu_text)
    expect_equal(true, menu_text:find('Shrink Selection%s+Ctrl%+Alt%+Down') ~= nil, menu_text)
end)

io.write('language servers\n')
local server_folder = harness.temporary_directory .. '/server-programs'
local project_folder = harness.temporary_directory .. '/lsp-project'
vim.fn.mkdir(server_folder, 'p')
vim.fn.mkdir(project_folder .. '/.git', 'p')
local original_path = harness.run_lua('return vim.env.PATH')
-- poll the editor until `code` returns true or time runs out. mine will too.
local function wait_for(code, milliseconds)
    return vim.wait(milliseconds or 5000, function()
        return harness.run_lua(code) == true
    end, 50)
end
-- lua returning every floating window's text. shit floats.
local floating_text_code = [[(function()
    local lines = {}
    for _, window in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(window).relative ~= '' then
            vim.list_extend(lines, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(window), 0, -1, false))
        end
    end
    return table.concat(lines, '\n')
end)()]]
local function open_document(file_name, lines)
    local path = project_folder .. '/' .. file_name
    vim.fn.writefile(lines, path)
    harness.run_lua('require("notebashpp.file_commands").open_path(...)', path)
    harness.wait_until_idle(200)
    return path
end
test_case('with no server programs on the path nothing starts and nothing fails', function()
    harness.run_lua('vim.env.PATH = ...; require("notebashpp.language_servers").look_again()', server_folder)
    for _, file_name in ipairs({ 'empty.lua', 'empty.py', 'empty.c', 'empty.ts', 'empty.rs', 'empty.go', 'empty.sh', 'empty.json', 'empty.md' }) do
        open_document(file_name, { 'text' })
    end
    harness.wait_until_idle(300)
    expect_equal(0, harness.run_lua('return #vim.lsp.get_clients()'), 'clients')
    expect_equal('Not on the path: marksman', harness.run_lua('return require("notebashpp.language_servers").status_line()'))
    harness.press_keys('<C-F12>')
    harness.press_keys('<F9>')
end)
test_case('a server on the path starts for its document; definition, references and problems work', function()
    local wrapper = server_folder .. '/lua-language-server'
    vim.fn.writefile({
        '#!/bin/sh',
        ("exec '%s' --clean -l '%s'"):format(vim.v.progpath, harness.project_root .. '/tests/fake_language_server.lua'),
    }, wrapper)
    vim.uv.fs_chmod(wrapper, tonumber('755', 8))
    harness.run_lua('require("notebashpp.language_servers").look_again()')
    open_document('main.lua', { 'local function helper()', 'end', 'helper() -- a problem', 'helper()' })
    -- lua_ls can run a project's own plugins, so it waits for trust.
    harness.wait_until_idle(300)
    expect_equal(0, harness.run_lua('return #vim.lsp.get_clients({ bufnr = 0 })'), 'not started before trust')
    expect_equal('lua_ls waits until you trust this folder', harness.run_lua('return require("notebashpp.language_servers").status_line()'))
    harness.run_lua([[local real_confirm = vim.fn.confirm
        vim.fn.confirm = function() return 1 end
        require("notebashpp.language_servers").trust_folder()
        vim.fn.confirm = real_confirm]])
    expect_equal(true, wait_for('return #vim.lsp.get_clients({ bufnr = 0 }) == 1 and #vim.diagnostic.get(0) == 1'), 'server attached, problem shown')
    expect_equal({ project_folder }, harness.run_lua('return require("notebashpp.preferences").get("trusted_language_server_folders", {})'), 'trusted list')
    expect_equal('Running: lua_ls', harness.run_lua('return require("notebashpp.language_servers").status_line()'))
    expect_equal(project_folder, harness.run_lua('return vim.lsp.get_clients({ bufnr = 0 })[1].root_dir'), 'project folder')
    expect_equal(false, harness.run_lua('return vim.diagnostic.config().virtual_text'), 'no virtual text')
    harness.run_lua('vim.cmd("startinsert")')
    harness.set_cursor_position(4, 2)
    harness.press_keys('<C-F12>')
    expect_equal(true, wait_for('local caret = vim.api.nvim_win_get_cursor(0) return caret[1] == 1 and caret[2] == 15'), 'went to the definition')
    expect_equal('i', harness.current_mode(), 'still typing')
    harness.press_keys('<S-F12>')
    expect_equal(true, wait_for('return vim.fn.getqflist({ size = 0 }).size == 3'), 'three references in the results panel')
    expect_equal(
        true,
        harness.run_lua('return vim.fn.getqflist({ title = 0 }).title'):find('References to "helper" (3 hits in 1 file)', 1, true) ~= nil,
        'title'
    )
    harness.run_lua('vim.cmd("cclose")')
    harness.set_cursor_position(1, 0)
    harness.press_keys('<F9>')
    expect_equal({ 3, 14 }, harness.cursor_position(), 'Next Problem')
    harness.wait_until_idle(100)
    local float_text = harness.run_lua('return ' .. floating_text_code)
    expect_equal(true, float_text:find('fake problem here', 1, true) ~= nil, 'details float: ' .. float_text)
    harness.press_keys('<Down>')
    local floats_left = harness.run_lua(
        'return #vim.tbl_filter(function(window) return vim.api.nvim_win_get_config(window).relative ~= "" and not vim.w[window].notebashpp_notification end, vim.api.nvim_list_wins())'
    )
    expect_equal(0, floats_left, 'float closed after moving')
    harness.set_cursor_position(3, 16)
    harness.request('nvim_input', '<Ignore>')
    expect_equal(true, wait_for('return ' .. floating_text_code .. ':find("fake problem here", 1, true) ~= nil', 2000), 'details when the caret rests')
    harness.press_keys('<Left>')
    harness.set_cursor_position(4, 1)
    harness.press_keys('<M-F12>')
    expect_equal(true, wait_for('return ' .. floating_text_code .. ':find("about helper", 1, true) ~= nil', 2000), 'documentation float')
    expect_equal('i', harness.current_mode(), 'still typing after the documentation')
    harness.type_text('x')
    expect_equal('hxelper()', harness.buffer_lines()[4], 'typing goes on')
    harness.type_text(' fake_')
    harness.press_keys('<Esc>')
    harness.press_keys('<C-Space>')
    expect_equal(
        true,
        wait_for('return vim.fn.pumvisible() == 1 and vim.fn.complete_info({ "items" }).items[1].word == "fake_completion"', 2000),
        'Ctrl+Space lists the server completion'
    )
    harness.press_keys('<C-e>')
    harness.press_keys('<M-p>')
    harness.press_keys('l')
    local menu_text = harness.run_lua([[local lines = {}
        for _, window in ipairs(vim.api.nvim_list_wins()) do
            if vim.api.nvim_win_get_config(window).relative ~= '' then
                vim.list_extend(lines, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(window), 0, -1, false))
            end
        end
        return table.concat(lines, '\n')]])
    harness.press_keys('<Esc>')
    harness.press_keys('<Esc>')
    expect_equal(true, menu_text:find('Running: lua_ls', 1, true) ~= nil, 'status in the menu: ' .. menu_text)
    expect_equal(true, menu_text:find('Go to Definition%s+Ctrl%+F12') ~= nil, 'definition in the menu')
end)
test_case('language_servers = false and the off list keep servers stopped', function()
    harness.run_lua(
        'require("notebashpp.user_settings").values.language_servers_off = { "lua-language-server" }; require("notebashpp.language_servers").look_again()'
    )
    expect_equal(true, wait_for('return #vim.lsp.get_clients() == 0'), 'stopped by the off list')
    expect_equal('Off in user.lua: lua_ls', harness.run_lua('return require("notebashpp.language_servers").status_line()'))
    harness.run_lua(
        'require("notebashpp.user_settings").values.language_servers_off = {}; require("notebashpp.user_settings").values.language_servers = false; require("notebashpp.language_servers").look_again()'
    )
    open_document('other.lua', { 'return 1' })
    harness.wait_until_idle(300)
    expect_equal(0, harness.run_lua('return #vim.lsp.get_clients()'), 'all off')
    harness.run_lua('require("notebashpp.user_settings").values.language_servers = true; vim.env.PATH = ...', original_path)
    harness.run_lua('vim.cmd("silent! %bwipeout!"); vim.cmd("startinsert")')
    harness.wait_until_idle()
end)

io.write('messages and key help\n')
local function notification_texts()
    return table.concat(harness.run_lua('return require("notebashpp.messages").visible_texts()'), '\n---\n')
end
local function message_log_text()
    return table.concat(harness.run_lua('return vim.fn.readfile(require("notebashpp.messages").log_path())'), '\n')
end
local function expect_typing_not_blocked(mode, description)
    expect_equal({ blocking = false, mode = 'i' }, mode, description)
end
-- test a key action raising a lua error & typing in an unchangeable document
-- (e21), with a screen attached as in real use. neither may leave a prompt
-- waiting for enter. the editor broke; why the hell does it need reassurance
-- from me???
local function check_errors_never_block(expected_message_ui)
    expect_equal(expected_message_ui, harness.run_lua('return require("notebashpp.messages").extended_ui_module_name ~= nil'), 'message ui on')
    start_with_lines({ 'abc' }, 1, 1)
    harness.run_lua([[local about = require('notebashpp.keybindings').by_id.about
        _G.real_about_action = about.fn
        about.fn = function() error('broken on purpose\nsecond line of the error') end]])
    expect_typing_not_blocked(harness.mode_after_keys('<F1>'), 'after the failing action')
    harness.run_lua('require("notebashpp.keybindings").by_id.about.fn = _G.real_about_action')
    harness.wait_until_idle()
    expect_equal(true, notification_texts():find('About Notebash++: ', 1, true) ~= nil, 'notification: ' .. notification_texts())
    expect_equal(true, notification_texts():find('broken on purpose', 1, true) ~= nil, 'error text shown')
    local message_log = message_log_text()
    expect_equal(true, message_log:find('ERROR About Notebash++: ', 1, true) ~= nil, 'logged: ' .. message_log)
    expect_equal(true, message_log:find('stack traceback:', 1, true) ~= nil, 'stack trace logged')
    expect_equal('rw-------', vim.fn.getfperm(harness.run_lua('return require("notebashpp.messages").log_path()')), 'log is private')
    harness.type_text('X')
    expect_equal('aXbc', harness.buffer_text(), 'typed keys still arrive')

    -- neovim checks 'modifiable' when typing starts, so leave typing & let
    -- modeless_editing.lua start it again before the buffer turns read-only.
    -- i am arranging my own rejection here.
    start_with_lines({ 'abc' }, 1, 1)
    harness.run_lua('vim.cmd.stopinsert()')
    harness.wait_until_idle()
    harness.run_lua('vim.bo.modifiable = false')
    for _, character in ipairs({ 'q', 'r', 's' }) do
        expect_typing_not_blocked(harness.mode_after_keys(character), 'after E21 from typing ' .. character)
    end
    harness.run_lua('vim.bo.modifiable = true')
    harness.wait_until_idle()
    expect_equal(true, notification_texts():find('E21: ', 1, true) ~= nil, 'E21 shown: ' .. notification_texts())
    expect_equal(true, message_log_text():find('ERROR E21: ', 1, true) ~= nil, 'E21 logged')
    expect_equal('abc', harness.buffer_text(), 'read-only text unchanged')
end
test_case('errors never block typing (with the message ui when Neovim has one)', function()
    harness.stop_editor()
    harness.start_editor({ listen = true })
    harness.attach_screen()
    local has_message_ui = harness.run_lua('return (pcall(require, "vim._core.ui2") or pcall(require, "vim._extui"))')
    check_errors_never_block(has_message_ui)
end)
test_case('errors never block typing (without the message ui, as on Neovim 0.11)', function()
    harness.stop_editor()
    harness.start_editor({ listen = true })
    harness.run_lua([[package.preload['vim._core.ui2'] = function() error('hidden for this test') end
        package.preload['vim._extui'] = package.preload['vim._core.ui2'] ]])
    harness.attach_screen()
    check_errors_never_block(false)
    expect_typing_not_blocked(harness.mode_after_keys('<Cmd>lua vim.api.nvim_echo({ { "one\\ntwo\\nthree\\nfour" } }, true, {})<CR>'), 'after a long echo')
    expect_equal(true, notification_texts():find('one\ntwo\nthree\nfour', 1, true) ~= nil, 'long echo shown as a notification')
end)
test_case('vim.notify shows a notification that fades and closes', function()
    -- fresh editor without a screen, keeping the errors above out of the
    -- final "no errors were raised" check. basically i have learned to bury
    -- evidence.
    harness.stop_editor()
    harness.start_editor()
    harness.run_lua('vim.notify("short lived", vim.log.levels.WARN)')
    harness.wait_until_idle()
    expect_equal(true, notification_texts():find('short lived', 1, true) ~= nil, 'shown')
    expect_equal(
        false,
        harness.run_lua([[for _, window in ipairs(vim.api.nvim_list_wins()) do
            if vim.w[window].notebashpp_notification then return vim.api.nvim_win_get_config(window).focusable end
        end]]),
        'not focusable'
    )
    expect_equal('i', harness.current_mode(), 'still typing')
    expect_equal(true, message_log_text():find('WARN short lived', 1, true) ~= nil, 'logged')
    harness.run_lua('require("notebashpp.messages").show("gone soon", { timeout = 50 })')
    vim.wait(1000)
    expect_equal(false, notification_texts():find('gone soon', 1, true) ~= nil, 'faded out')
end)
test_case('Help > Message log opens the log read-only', function()
    harness.run_lua('vim.notify("for the log viewer", vim.log.levels.ERROR)')
    harness.run_lua('require("notebashpp.keybindings").run("message_log")')
    harness.wait_until_idle()
    expect_equal(harness.run_lua('return require("notebashpp.messages").log_path()'), harness.run_lua('return vim.api.nvim_buf_get_name(0)'), 'log open')
    expect_equal(false, harness.run_lua('return vim.bo.modifiable'), 'read-only')
    expect_equal(true, harness.buffer_text():find('ERROR for the log viewer', 1, true) ~= nil, 'entry visible')
    harness.run_lua('vim.notify("added while the log is open", vim.log.levels.WARN)')
    harness.run_lua('require("notebashpp.keybindings").run("message_log")')
    harness.wait_until_idle()
    expect_equal(true, harness.buffer_text():find('WARN added while the log is open', 1, true) ~= nil, 'new entry visible')
    expect_equal(false, harness.run_lua('return vim.bo.modifiable'), 'still read-only')
    harness.run_lua('vim.cmd("enew!")')
    harness.wait_until_idle()
end)
test_case('Shift+F1 then a key says what the key does without running it', function()
    start_with_lines({ 'abc' }, 1, 0)
    harness.press_keys('<S-F1>')
    expect_equal(true, notification_texts():find('Press a key combination', 1, true) ~= nil, 'asks for a key')
    harness.press_keys('<C-f>')
    local answer = notification_texts()
    expect_equal(true, answer:find('Ctrl+F: Find...\nMenu: Search\nKeys: Ctrl+F\nId: find', 1, true) ~= nil, 'answer: ' .. answer)
    expect_equal(false, answer:find('Press a key combination', 1, true) ~= nil, 'question closed')
    expect_equal('', harness.run_lua('return vim.bo.filetype'), 'Find did not open')
    expect_equal('i', harness.current_mode(), 'still typing')
    harness.press_keys('<S-F1>')
    harness.press_keys('<C-ד>')
    expect_equal(true, notification_texts():find('Ctrl+S: Save\nMenu: File', 1, true) ~= nil, 'Hebrew layout: ' .. notification_texts())
    harness.press_keys('<S-F1>')
    harness.press_keys('<F13>')
    expect_equal(true, notification_texts():find('Shift+F1: What does this key do?\nMenu: Help', 1, true) ~= nil, 'terminal Shift+F1')
    harness.press_keys('<S-F1>')
    harness.press_keys('<C-S-y>')
    expect_equal(true, notification_texts():find('Ctrl+Shift+Y is not bound.', 1, true) ~= nil, 'unbound key')
    harness.press_keys('<S-F1>')
    harness.press_keys('<C-z>')
    expect_equal(
        true,
        notification_texts():find('Ctrl+Z: Undo\nMenu: Edit\nKeys: Ctrl+Z, Alt+Backspace', 1, true) ~= nil,
        'every key: ' .. notification_texts()
    )
    harness.press_keys('<S-F1>')
    harness.press_keys('<Esc>')
    expect_equal(false, notification_texts():find('Press a key combination', 1, true) ~= nil, 'Esc cancels')
    harness.type_text('X')
    expect_equal('Xabc', harness.buffer_text(), 'no key ran, typing goes on')
end)

io.write('remote documents\n')
-- a stand-in ssh: skips options up to --, drops the host, runs the command
-- here. a real server would cost money, and i've spent mine.
local remote_folder = harness.temporary_directory .. '/remote'
local fake_programs = harness.temporary_directory .. '/fake-programs'
vim.fn.mkdir(remote_folder, 'p')
vim.fn.mkdir(fake_programs, 'p')
vim.fn.writefile({
    '#!/bin/sh',
    'while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done',
    'shift 2',
    'exec sh -c "$1"',
}, fake_programs .. '/ssh')
vim.uv.fs_chmod(fake_programs .. '/ssh', tonumber('755', 8))
local function with_fake_ssh(code, ...)
    return harness.run_lua('vim.env.PATH = ' .. vim.inspect(fake_programs) .. ' .. ":" .. vim.env.PATH; ' .. code, ...)
end
test_case('host:/path opens a file over ssh, and Ctrl+S writes it back in place', function()
    local remote_file = remote_folder .. "/it's $(touch PROOF).conf"
    vim.fn.writefile({ 'listen 80;', 'server_name example.com;' }, remote_file)
    vim.uv.fs_chmod(remote_file, tonumber('640', 8))
    local inode_before = vim.uv.fs_stat(remote_file).ino
    with_fake_ssh('require("notebashpp.file_commands").open_path(...)', 'prod:' .. remote_file)
    harness.wait_until_idle()
    expect_equal('ssh://prod' .. remote_file, harness.run_lua('return vim.api.nvim_buf_get_name(0)'), 'buffer name')
    expect_equal({ 'listen 80;', 'server_name example.com;' }, harness.buffer_lines(), 'content')
    expect_equal(
        true,
        harness.run_lua(
            'return require("notebashpp.document_tabs").sync and vim.tbl_contains(require("notebashpp.document_tabs").sync(), vim.api.nvim_get_current_buf())'
        ),
        'a tab'
    )
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, 1, false, { "listen 443 ssl;" })')
    expect_equal(true, with_fake_ssh('return require("notebashpp.file_commands").save()'), 'saved')
    expect_equal({ 'listen 443 ssl;', 'server_name example.com;' }, vim.fn.readfile(remote_file), 'on the server')
    expect_equal(inode_before, vim.uv.fs_stat(remote_file).ino, 'same file, not replaced')
    expect_equal('rw-r-----', vim.fn.getfperm(remote_file), 'permissions kept')
    expect_equal(false, harness.run_lua('return vim.bo.modified'), 'not modified')
    expect_equal(0, vim.fn.filereadable(harness.temporary_directory .. '/PROOF') + vim.fn.filereadable(remote_folder .. '/PROOF'), 'payload ran')
    harness.run_lua('vim.cmd("enew!")')
end)
test_case('a new file over ssh opens empty and Ctrl+S creates it', function()
    local remote_file = remote_folder .. '/new.txt'
    with_fake_ssh('require("notebashpp.file_commands").open_path(...)', 'ssh://prod' .. remote_file)
    harness.wait_until_idle()
    expect_equal({ '' }, harness.buffer_lines(), 'empty')
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, { "fresh" })')
    expect_equal(true, with_fake_ssh('return require("notebashpp.file_commands").save()'), 'saved')
    expect_equal({ 'fresh' }, vim.fn.readfile(remote_file), 'created')
    harness.run_lua('vim.cmd("enew!")')
end)
test_case('a web address opens as text, and an html page as html or markdown', function()
    local web_folder = harness.temporary_directory .. '/web'
    vim.fn.mkdir(web_folder, 'p')
    vim.fn.writefile({ '<html><body><h1>Regrets</h1><p>Too <b>many</b>.</p></body></html>' }, web_folder .. '/page.html')
    vim.fn.writefile({ '{"a": 1}' }, web_folder .. '/data.json')
    local port = 20000 + vim.uv.os_getpid() % 20000
    local server = vim.fn.jobstart({ 'python3', '-m', 'http.server', tostring(port), '--bind', '127.0.0.1' }, { cwd = web_folder })
    local base = 'http://127.0.0.1:' .. port
    vim.wait(5000, function()
        return vim.system({ 'curl', '-s', '-o', '/dev/null', base .. '/data.json' }):wait().code == 0
    end, 100)
    harness.run_lua('require("notebashpp.file_commands").open_path(...)', base .. '/data.json')
    harness.wait_until_idle()
    expect_equal({ '{"a": 1}' }, harness.buffer_lines(), 'json text')
    expect_equal('json', harness.run_lua('return vim.bo.filetype'), 'json filetype')
    local saved_path = web_folder .. '/saved.json'
    harness.run_lua(
        [[local helpers = require("notebashpp.helpers")
        local real_ask = helpers.ask
        local chosen_path = ...
        helpers.ask = function() return chosen_path end
        require("notebashpp.file_commands").save()
        helpers.ask = real_ask]],
        saved_path
    )
    expect_equal({ '{"a": 1}' }, vim.fn.readfile(saved_path), 'saved locally')
    expect_equal(saved_path, harness.run_lua('return vim.api.nvim_buf_get_name(0)'), 'now a local document')
    expect_equal('', harness.run_lua('return vim.bo.buftype'), 'plain buffer')
    local function open_page(choice, query)
        harness.run_lua([[local real_confirm = vim.fn.confirm
            vim.fn.confirm = function() return ]] .. choice .. [[ end
            require("notebashpp.file_commands").open_path(...)
            vim.fn.confirm = real_confirm]], base .. '/page.html' .. query)
        harness.wait_until_idle()
    end
    open_page(1, '?as=html')
    expect_equal('html', harness.run_lua('return vim.bo.filetype'), 'html')
    expect_equal(true, harness.buffer_text():find('<h1>Regrets</h1>', 1, true) ~= nil, 'html source')
    open_page(2, '?as=markdown')
    if vim.fn.executable('pandoc') == 1 then
        expect_equal('markdown', harness.run_lua('return vim.bo.filetype'), 'markdown')
        expect_equal('# Regrets', harness.buffer_lines()[1], 'converted')
    else
        expect_equal('html', harness.run_lua('return vim.bo.filetype'), 'html without pandoc')
    end
    vim.fn.jobstop(server)
    harness.run_lua('vim.cmd("enew!")')
end)
io.write('hostile text\n')
-- every payload here writes a proof file if it runs. nothing shows up? we
-- pass. basically i gave malicious code a purpose. still looking for mine.
local proof_path = harness.temporary_directory .. '/PROOF'
test_case('Replace All with a slash in the find text', function()
    start_with_lines({ 'a/b and a/b' }, 1, 0)
    harness.run_lua([[local find_and_replace = require("notebashpp.find_and_replace")
        find_and_replace.state.find = "a/b"; find_and_replace.state.replace = "c"; find_and_replace.state.mode = "normal"; find_and_replace.state.in_selection = false; find_and_replace.state.wrap = true
        find_and_replace.replace_all(false)]])
    harness.wait_until_idle()
    expect_equal('c and c', harness.buffer_text())
end)
test_case('Replace All with a slash in a regex', function()
    start_with_lines({ 'a/b and a/b' }, 1, 0)
    harness.run_lua([[local find_and_replace = require("notebashpp.find_and_replace")
        find_and_replace.state.find = "a/(b)"; find_and_replace.state.replace = "$1"; find_and_replace.state.mode = "regex"; find_and_replace.state.in_selection = false; find_and_replace.state.wrap = true
        find_and_replace.replace_all(false)]])
    harness.wait_until_idle()
    expect_equal('b and b', harness.buffer_text())
end)
test_case('find text cannot run commands through Replace All or Replace', function()
    local hostile_find_text = 'x/y/e|call writefile(["1"], "PROOF")|"'
    for _, mode in ipairs({ 'normal', 'regex', 'extended' }) do
        start_with_lines({ hostile_find_text, 'x\\y' }, 1, 0)
        harness.run_lua(
            [[local find_and_replace = require("notebashpp.find_and_replace")
            find_and_replace.state.find = ...; find_and_replace.state.replace = "z"; find_and_replace.state.mode = select(2, ...); find_and_replace.state.in_selection = false; find_and_replace.state.wrap = true
            pcall(find_and_replace.replace_all, false)
            vim.api.nvim_win_set_cursor(0, { 1, 0 })
            pcall(find_and_replace.replace_one)]],
            hostile_find_text,
            mode
        )
        harness.wait_until_idle()
        expect_equal(0, vim.fn.filereadable(proof_path), mode .. ' mode ran the payload')
    end
end)
test_case('Replace in Files stays inside its folder when a file name has a newline', function()
    local search_directory = harness.temporary_directory .. '/rif-trap'
    local outside_file = harness.temporary_directory .. '/outside/notes.txt'
    vim.fn.mkdir(vim.fs.dirname(outside_file), 'p')
    vim.fn.writefile({ 'needle' }, outside_file)
    local trap_file = search_directory .. '/trap\n' .. outside_file
    vim.fn.mkdir(vim.fs.dirname(trap_file), 'p')
    vim.fn.writefile({ 'needle' }, trap_file)
    vim.fn.writefile({ 'needle' }, search_directory .. '/inside.txt')
    harness.run_lua(
        [[local find_and_replace = require("notebashpp.find_and_replace")
        find_and_replace.state.find = "needle"; find_and_replace.state.replace = "pin"; find_and_replace.state.mode = "normal"; find_and_replace.state.dir = ...; find_and_replace.state.filters = "*.*"
        find_and_replace.state.subfolders = true; find_and_replace.state.hidden = false
        local real_confirm = vim.fn.confirm
        vim.fn.confirm = function() return 1 end
        find_and_replace.replace_in_files()
        vim.fn.confirm = real_confirm]],
        search_directory
    )
    harness.wait_until_idle(1500)
    expect_equal({ 'needle' }, vim.fn.readfile(outside_file), 'file outside the folder')
    expect_equal({ 'pin' }, vim.fn.readfile(search_directory .. '/inside.txt'), 'file inside')
    expect_equal({ 'pin' }, vim.fn.readfile(trap_file), 'file under the newline folder')
    harness.run_lua('require("notebashpp.find_and_replace").state.replace = ""')
end)
test_case('opening a file named with backticks opens it and runs nothing', function()
    local hostile_path = harness.temporary_directory .. '/report`touch PROOF`.txt'
    vim.fn.writefile({ 'inside' }, hostile_path)
    harness.run_lua('require("notebashpp.file_commands").open_path(...)', hostile_path)
    harness.wait_until_idle()
    expect_equal(0, vim.fn.filereadable(proof_path), 'payload ran')
    expect_equal(hostile_path, harness.run_lua('return vim.api.nvim_buf_get_name(0)'))
    expect_equal('inside', harness.buffer_text())
    harness.run_lua('vim.cmd("enew!"); vim.cmd("silent! bwipeout! " .. vim.fn.bufnr(...))', hostile_path)
    vim.fn.delete(hostile_path)
end)
test_case('a modeline or an odd encoding name cannot run code through the status bar', function()
    local modeline_path = harness.temporary_directory .. '/modeline.txt'
    vim.fn.writefile({ 'hello', '# vim: set fenc=%{%v\\:lua.os.execute(\\"touch\\ ' .. proof_path .. '\\")%}:' }, modeline_path)
    harness.run_lua('require("notebashpp.file_commands").open_path(...)', modeline_path)
    harness.wait_until_idle()
    expect_equal(false, harness.run_lua('return vim.bo.modeline'), 'modelines off')
    harness.run_lua('vim.bo.fileencoding = ...', '%{%v:lua.os.execute("touch ' .. proof_path .. '")%}')
    local status_text = harness.run_lua('return vim.api.nvim_eval_statusline(vim.o.statusline, { maxwidth = 1000 }).str')
    expect_equal(0, vim.fn.filereadable(proof_path), 'payload ran')
    expect_equal(true, status_text:find('os.execute(', 1, true) ~= nil, 'shown as text: ' .. status_text)
    harness.run_lua('vim.cmd("enew!"); vim.cmd("silent! bwipeout! " .. vim.fn.bufnr(...))', modeline_path)
end)
test_case('a regex that would take forever stops after 2 seconds and changes nothing', function()
    start_with_lines({ string.rep('a', 100), 'hello' }, 1, 0)
    local started = vim.uv.hrtime()
    harness.run_lua([[local find_and_replace = require("notebashpp.find_and_replace")
        find_and_replace.state.find = "(a+)+\\1b"; find_and_replace.state.replace = "x"; find_and_replace.state.mode = "regex"; find_and_replace.state.in_selection = false; find_and_replace.state.wrap = true
        find_and_replace.replace_all(false)
        find_and_replace.count()]])
    local seconds = (vim.uv.hrtime() - started) / 1e9
    expect_equal(true, seconds < 8, ('took %.1f s'):format(seconds))
    expect_equal({ string.rep('a', 100), 'hello' }, harness.buffer_lines(), 'unchanged')
end)
test_case('Replace in Files skips a binary file whose zero byte comes late', function()
    local search_directory = harness.temporary_directory .. '/rif-binary'
    vim.fn.mkdir(search_directory, 'p')
    local binary_path = search_directory .. '/data.bin'
    local binary_file = assert(io.open(binary_path, 'wb'))
    binary_file:write('needle ' .. string.rep('x', 300000) .. '\0tail')
    binary_file:close()
    harness.run_lua(
        [[local find_and_replace = require("notebashpp.find_and_replace")
        find_and_replace.state.find = "needle"; find_and_replace.state.replace = "pin"; find_and_replace.state.mode = "normal"; find_and_replace.state.dir = ...; find_and_replace.state.filters = "*.*"
        find_and_replace.state.subfolders = true; find_and_replace.state.hidden = false
        local real_confirm = vim.fn.confirm
        vim.fn.confirm = function() return 1 end
        find_and_replace.replace_in_files()
        vim.fn.confirm = real_confirm]],
        search_directory
    )
    harness.wait_until_idle(1500)
    local read_back = assert(io.open(binary_path, 'rb'))
    local content = read_back:read('*a')
    read_back:close()
    expect_equal('needle ', content:sub(1, 7), 'binary file untouched')
    harness.run_lua('require("notebashpp.find_and_replace").state.replace = ""')
end)
test_case('a wrong type in preferences.json falls back to the default', function()
    harness.run_lua('require("notebashpp.preferences").set("spell_check", "yes")')
    expect_equal(false, harness.run_lua('return require("notebashpp.preferences").get("spell_check", false)'))
    harness.run_lua('require("notebashpp.preferences").set("spell_check", false)')
end)
test_case('Run passes file names and line text to the shell as data', function()
    local hostile_name = harness.temporary_directory .. '/$(touch PROOF)`touch PROOF`.txt'
    start_with_lines({ 'it\'s "quoted" $(touch ' .. proof_path .. ')' }, 1, 0)
    local command_line, environment = unpack(harness.run_lua(
        [[
        vim.api.nvim_buf_set_name(0, ...)
        return { require("notebashpp.run_commands").shell_command_with_variables(
            [=[printf '%s|%s|%s|%s\n' "$(FULL_CURRENT_PATH)" $(FILE_NAME) '$(CURRENT_LINESTR)' line$(CURRENT_LINE)]=]) }]],
        hostile_name
    ))
    local output = vim.system({ 'sh', '-c', command_line }, { env = environment, text = true, cwd = harness.temporary_directory }):wait().stdout
    expect_equal(0, vim.fn.filereadable(proof_path), 'payload ran')
    expect_equal(hostile_name .. '|' .. vim.fs.basename(hostile_name) .. '|it\'s "quoted" $(touch ' .. proof_path .. ')|line1\n', output)
    harness.run_lua('vim.cmd("enew!")')
end)

test_case('the launcher treats hostile names as files and keeps its socket private', function()
    local launch_directory = harness.temporary_directory .. '/launcher'
    vim.fn.mkdir(launch_directory, 'p')
    local environment = {
        XDG_CONFIG_HOME = launch_directory .. '/config',
        XDG_DATA_HOME = launch_directory .. '/data',
        -- short runtime folder: macos allows 104 characters in a socket path.
        -- the test's temporary folder eats most of them, like rent eating
        -- what's left of my damn life.
        XDG_STATE_HOME = launch_directory .. '/state',
        XDG_RUNTIME_DIR = '/tmp/nvpp-' .. vim.uv.os_getpid(),
        NOTEBASHPP_TEST = '1',
        NOTEBASHPP_NO_SESSION = '1',
    }
    vim.fn.mkdir(environment.XDG_RUNTIME_DIR, 'p')
    local launcher = harness.project_root .. '/bin/notebash++'
    local hostile_names = { '+call writefile(["1"], "PROOF")', '-n1|call writefile(["1"], "PROOF")', '--cmd' }
    local channel =
        vim.fn.jobstart(vim.list_extend({ launcher, '--embed', '--' }, vim.deepcopy(hostile_names)), { rpc = true, env = environment, cwd = launch_directory })
    vim.wait(3000, function()
        return pcall(vim.rpcrequest, channel, 'nvim_eval', '1')
    end)
    local opened = vim.rpcrequest(
        channel,
        'nvim_exec_lua',
        [[local names = {}
        for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[buffer].buflisted and vim.api.nvim_buf_get_name(buffer) ~= '' then names[#names + 1] = vim.fs.basename(vim.api.nvim_buf_get_name(buffer)) end
        end
        table.sort(names)
        return names]],
        {}
    )
    local sorted_names = vim.deepcopy(hostile_names)
    table.sort(sorted_names)
    expect_equal(sorted_names, opened, 'files opened')
    local socket_directory = environment.XDG_RUNTIME_DIR .. '/notebashpp-' .. vim.uv.getuid()
    expect_equal('rwx------', vim.fn.getfperm(socket_directory), 'socket folder')
    local second_file = launch_directory .. '/$(touch PROOF)`touch PROOF`.txt'
    vim.fn.writefile({ 'second' }, second_file)
    local second_launch = vim.system(
        { launcher, '-n1|call writefile(["1"], "PROOF")', '--', second_file },
        { env = environment, cwd = launch_directory, text = true }
    )
        :wait(10000)
    expect_equal('Opened in the running Notebash++.\n', second_launch.stdout, 'second launch: ' .. tostring(second_launch.stderr))
    vim.wait(3000, function()
        return vim.rpcrequest(channel, 'nvim_exec_lua', 'return vim.api.nvim_buf_get_name(0)', {}) == second_file
    end, 50)
    expect_equal(second_file, vim.rpcrequest(channel, 'nvim_exec_lua', 'return vim.api.nvim_buf_get_name(0)', {}), 'handed over')
    expect_equal(0, vim.fn.filereadable(launch_directory .. '/PROOF'), 'payload ran')
    vim.fn.jobstop(channel)
    vim.fn.delete(environment.XDG_RUNTIME_DIR, 'rf')
end)

test_case('the launcher (and its short name nbpp) turns host:/path into an ssh document', function()
    local launch_directory = harness.temporary_directory .. '/launcher-remote'
    vim.fn.mkdir(launch_directory, 'p')
    vim.fn.writefile({ 'local' }, launch_directory .. '/notes:~draft.txt')
    local environment = {
        XDG_CONFIG_HOME = launch_directory .. '/config',
        XDG_DATA_HOME = launch_directory .. '/data',
        XDG_STATE_HOME = launch_directory .. '/state',
        XDG_RUNTIME_DIR = '/tmp/nvpr-' .. vim.uv.os_getpid(),
        NOTEBASHPP_TEST = '1',
        NOTEBASHPP_NO_SESSION = '1',
        PATH = fake_programs .. ':' .. vim.env.PATH,
    }
    vim.fn.mkdir(environment.XDG_RUNTIME_DIR, 'p')
    local short_launcher = harness.project_root .. '/bin/nbpp'
    local channel = vim.fn.jobstart(
        { short_launcher, '--embed', '-multiInst', 'prod:/nowhere/new.conf', 'deploy@web-1:~/site/index.html', 'notes:~draft.txt' },
        { rpc = true, env = environment, cwd = launch_directory }
    )
    vim.wait(5000, function()
        return pcall(vim.rpcrequest, channel, 'nvim_eval', '1')
    end)
    local opened = vim.rpcrequest(
        channel,
        'nvim_exec_lua',
        [[local names = {}
        for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[buffer].buflisted and vim.api.nvim_buf_get_name(buffer) ~= '' then names[#names + 1] = vim.api.nvim_buf_get_name(buffer) end
        end
        table.sort(names)
        return names]],
        {}
    )
    expect_equal({ launch_directory .. '/notes:~draft.txt', 'ssh://deploy@web-1/~/site/index.html', 'ssh://prod/nowhere/new.conf' }, opened, 'documents')
    vim.fn.jobstop(channel)
    vim.fn.delete(environment.XDG_RUNTIME_DIR, 'rf')
end)
-- test the launcher with no nvim on path. a fake release tarball lives in a
-- local folder, read via file:// with a matching sha-256. both overrides
-- require notebashpp_test=1. real neovim is never downloaded here (i have
-- enough actual problems without fetching another one).
test_case('the launcher installs a private Neovim only when asked and checks its checksum', function()
    local uname = vim.uv.os_uname()
    local system_names = { Linux = 'linux', Darwin = 'macos' }
    local machine_names = { x86_64 = 'x86_64', amd64 = 'x86_64', aarch64 = 'arm64', arm64 = 'arm64' }
    if not system_names[uname.sysname] or not machine_names[uname.machine] then
        return
    end
    local release_name = ('nvim-%s-%s'):format(system_names[uname.sysname], machine_names[uname.machine])
    local launcher = harness.project_root .. '/bin/notebash++'
    local pinned_tag = table.concat(vim.fn.readfile(launcher), '\n'):match('PINNED_NEOVIM_TAG="(v[%d.]+)"')
    assert(pinned_tag, 'pinned tag not found in the launcher')

    -- fake nvim answers the version flag like the pinned release, then logs
    -- arguments instead of starting an editor. basically my most useful
    -- editor.
    local install_directory = harness.temporary_directory .. '/neovim-install'
    local release_directory = install_directory .. '/release'
    local fake_neovim = release_directory .. '/' .. release_name .. '/bin/nvim'
    vim.fn.mkdir(vim.fs.dirname(fake_neovim), 'p')
    vim.fn.writefile({
        '#!/bin/sh',
        'if [ "$1" = --version ]; then echo "NVIM ' .. pinned_tag .. '"; exit 0; fi',
        'printf "%s\\n" "$@" >"$FAKE_NEOVIM_LOG"',
    }, fake_neovim)
    vim.uv.fs_chmod(fake_neovim, tonumber('755', 8))
    local archive = release_directory .. '/' .. release_name .. '.tar.gz'
    local packed = vim.system({ 'tar', '-czf', archive, '-C', release_directory, release_name }):wait(10000)
    expect_equal(0, packed.code, 'tar: ' .. tostring(packed.stderr))
    local checksum_command = vim.fn.executable('sha256sum') == 1 and { 'sha256sum', '--', archive } or { 'shasum', '-a', '256', '--', archive }
    local archive_sha256 = vim.system(checksum_command, { text = true }):wait(10000).stdout:match('^(%x+)')

    -- a private path: only the launcher's tools, no nvim. some peace at last.
    local tool_directory = install_directory .. '/tools'
    vim.fn.mkdir(tool_directory, 'p')
    local tools = { 'bash', 'dirname', 'readlink', 'mkdir', 'id', 'grep', 'head', 'sed', 'uname', 'getconf', 'curl' }
    vim.list_extend(tools, { 'sha256sum', 'shasum', 'perl', 'tar', 'gzip', 'mv', 'rm', 'rmdir', 'mktemp', 'wc', 'timeout', 'chmod', 'ln' })
    for _, tool in ipairs(tools) do
        local tool_path = vim.fn.exepath(tool)
        if tool_path ~= '' then
            vim.uv.fs_symlink(tool_path, tool_directory .. '/' .. tool)
        end
    end
    local data_directory = install_directory .. '/data'
    local private_root = data_directory .. '/notebashpp/neovim'
    local installed_neovim = ('%s/%s-%s/bin/nvim'):format(private_root, release_name, pinned_tag)
    local log_path = install_directory .. '/fake-neovim.log'
    local environment = {
        HOME = install_directory,
        PATH = tool_directory,
        XDG_CONFIG_HOME = install_directory .. '/config',
        XDG_DATA_HOME = data_directory,
        XDG_STATE_HOME = install_directory .. '/state',
        XDG_RUNTIME_DIR = '/tmp/nvpp-i-' .. vim.uv.os_getpid(),
        NOTEBASHPP_TEST = '1',
        NOTEBASHPP_TEST_EXACT_PATH = '1',
        NOTEBASHPP_NEOVIM_DOWNLOAD_BASE = 'file://' .. release_directory,
        NOTEBASHPP_NEOVIM_SHA256 = archive_sha256,
        FAKE_NEOVIM_LOG = log_path,
    }
    -- jobstart, not vim.system: on neovim 0.11.0 vim.system():wait() here
    -- sometimes came back late or with another run's exit code.
    local function launch(arguments, extra_environment)
        local output = { stdout = {}, stderr = {} }
        local job = vim.fn.jobstart(vim.list_extend({ launcher }, arguments), {
            env = vim.tbl_extend('force', environment, extra_environment or {}),
            clear_env = true,
            cwd = install_directory,
            stdout_buffered = true,
            stderr_buffered = true,
            on_stdout = function(_, lines)
                output.stdout = lines
            end,
            on_stderr = function(_, lines)
                output.stderr = lines
            end,
        })
        local code = vim.fn.jobwait({ job }, 20000)[1]
        if code == -1 then
            vim.fn.jobstop(job)
            code = 124
        end
        return { code = code, stdout = table.concat(output.stdout, '\n'), stderr = table.concat(output.stderr, '\n') }
    end
    local function private_root_entries()
        local entries = {}
        for name in vim.fs.dir(private_root) do
            entries[#entries + 1] = name
        end
        return entries
    end

    local no_terminal = launch({ 'notes.txt' })
    expect_equal(1, no_terminal.code, 'no terminal: exit code')
    expect_equal(nil, no_terminal.stderr:find('[y/N]', 1, true), 'no terminal: asked anyway: ' .. no_terminal.stderr)
    expect_equal(true, no_terminal.stderr:find('-installNeovim', 1, true) ~= nil, 'no terminal: hint: ' .. no_terminal.stderr)
    expect_equal({}, private_root_entries(), 'no terminal: installed anyway')

    local wrong_checksum = launch({ '-installNeovim' }, { NOTEBASHPP_NEOVIM_SHA256 = string.rep('0', 64) })
    expect_equal(1, wrong_checksum.code, 'wrong checksum: exit code')
    expect_equal(true, wrong_checksum.stderr:find('checksum', 1, true) ~= nil, 'wrong checksum: message: ' .. wrong_checksum.stderr)
    expect_equal({}, private_root_entries(), 'wrong checksum: left behind')

    local installed = launch({ '-installNeovim' })
    expect_equal(0, installed.code, 'install: ' .. installed.stderr)
    expect_equal(1, vim.fn.executable(installed_neovim), 'install: private nvim')
    expect_equal({ release_name .. '-' .. pinned_tag }, private_root_entries(), 'install: only the release folder')

    -- the second run must not download again. its download address points to
    -- a nonexistent folder (same address as my hopes).
    local reused = launch({ 'notes.txt' }, { NOTEBASHPP_NEOVIM_DOWNLOAD_BASE = 'file:///nonexistent' })
    expect_equal(0, reused.code, 'second run: ' .. reused.stderr)
    local logged_arguments = vim.fn.readfile(log_path)
    expect_equal({ '--', 'notes.txt' }, vim.list_slice(logged_arguments, #logged_arguments - 1), 'second run: arguments')
    local already_installed = launch({ '-installNeovim' }, { NOTEBASHPP_NEOVIM_DOWNLOAD_BASE = 'file:///nonexistent' })
    expect_equal(true, already_installed.stdout:find(installed_neovim, 1, true) ~= nil, 'second install: ' .. already_installed.stdout)
    vim.fn.delete(environment.XDG_RUNTIME_DIR, 'rf')
end)

io.write('spreadsheet and large files\n')
local sheet_directory = harness.temporary_directory .. '/sheets'
vim.fn.mkdir(sheet_directory, 'p')
local function write_bytes(path, text)
    local file = assert(io.open(path, 'wb'))
    file:write(text)
    file:close()
end
local function read_bytes(path)
    local file = assert(io.open(path, 'rb'))
    local text = file:read('*a')
    file:close()
    return text
end
-- open a file & wait for the background count to finish. there goes my life.
local function open_sheet(path)
    harness.run_lua('vim.cmd.edit(...)', path)
    harness.wait_until_idle(100)
    for _ = 1, 100 do
        local done = harness.run_lua([[
            local view = vim.b.notebashpp_special_view
            if not view then return true end
            local state = require('notebashpp.' .. view).current_state()
            return state == nil or state.index.complete
        ]])
        if done then
            break
        end
        vim.wait(50)
    end
    harness.wait_until_idle(60)
end
local function sheet_value(expression)
    return harness.run_lua('local state = require("notebashpp.spreadsheet_view").current_state(); return ' .. expression)
end
local function save_sheet()
    harness.press_keys('<C-s>', 100)
    for _ = 1, 100 do
        if not sheet_value('state.saving') and sheet_value('state.index.complete') then
            break
        end
        vim.wait(50)
    end
    harness.wait_until_idle(100)
end
local sample_csv = 'name,city,amount\r\nAmos,"Tel Aviv",12.5\r\n"Cohen, Dana",Haifa,7\r\n"two\r\nlines",x,1\r\n'

test_case('a csv opens as a spreadsheet with a header row and row numbers', function()
    local path = sheet_directory .. '/people.csv'
    write_bytes(path, sample_csv)
    open_sheet(path)
    expect_equal('spreadsheet_view', harness.run_lua('return vim.b.notebashpp_special_view'), 'view')
    expect_equal('n', harness.current_mode(), 'not typing into the drawn grid')
    local lines = harness.buffer_lines()
    expect_equal(true, lines[1]:find('name', 1, true) ~= nil and lines[1]:find('amount', 1, true) ~= nil, 'header: ' .. lines[1])
    expect_equal(true, lines[3]:find('Cohen, Dana', 1, true) ~= nil, 'quoted comma kept in one cell: ' .. lines[3])
    expect_equal(true, lines[4]:find('two¶lines', 1, true) ~= nil, 'line break inside a cell: ' .. lines[4])
    expect_equal(3, sheet_value('#state.columns'), 'columns')
    local status = harness.run_lua('return require("notebashpp.status_bar").render()')
    expect_equal(true, status:find('CSV spreadsheet', 1, true) ~= nil and status:find('of 3', 1, true) ~= nil, 'status: ' .. status)
    expect_equal(true, harness.run_lua('return vim.fn.getbufinfo(vim.api.nvim_get_current_buf())[1].listed == 1'), 'listed as a tab')
end)

test_case('typing replaces a cell, enter moves down, ctrl+s writes only that row anew', function()
    local path = sheet_directory .. '/people.csv'
    write_bytes(path, sample_csv)
    harness.run_lua('vim.cmd("edit!")')
    open_sheet(path)
    harness.press_keys('<C-Home><Down><Right>')
    harness.type_text('Jaffa')
    harness.press_keys('<CR>', 100)
    expect_equal({ 1, 2 }, { sheet_value('state.cursor_row'), sheet_value('state.cursor_column') }, 'caret one row down')
    expect_equal(true, harness.run_lua('return vim.bo.modified'), 'modified')
    save_sheet()
    expect_equal('name,city,amount\r\nAmos,Jaffa,12.5\r\n"Cohen, Dana",Haifa,7\r\n"two\r\nlines",x,1\r\n', read_bytes(path), 'file')
    expect_equal(false, harness.run_lua('return vim.bo.modified'), 'saved')
end)

test_case('Hebrew typed into a cell, fast keys keep their order', function()
    local path = sheet_directory .. '/people.csv'
    harness.press_keys('<C-Home><Down>')
    harness.request('nvim_input', 'שלום<Tab>ok<CR>')
    harness.wait_until_idle(200)
    expect_equal('שלום', sheet_value('state.edits[1][1]'), 'first cell')
    expect_equal('ok', sheet_value('state.edits[1][2]'), 'tab moved to the next cell')
    save_sheet()
    expect_equal('name,city,amount\r\nשלום,ok,12.5\r\n', read_bytes(path):sub(1, #'name,city,amount\r\nשלום,ok,12.5\r\n'), 'file')
end)

test_case('undo and redo in a spreadsheet', function()
    harness.press_keys('<C-Home><Down><Down>')
    harness.type_text('Z')
    harness.press_keys('<CR>', 100)
    expect_equal('Z', sheet_value('state.edits[2][1]'), 'edited')
    harness.press_keys('<C-z>', 60)
    expect_equal(true, sheet_value('state.edits[2] == nil or state.edits[2][1] == nil'), 'undone')
    expect_equal(false, harness.run_lua('return vim.bo.modified'), 'back to saved')
    harness.press_keys('<C-y>', 60)
    expect_equal('Z', sheet_value('state.edits[2][1]'), 'redone')
    harness.press_keys('<C-z>', 60)
end)

test_case('rows and columns: duplicate, delete, insert and delete columns', function()
    local path = sheet_directory .. '/rows.csv'
    write_bytes(path, 'a,b,c\n1,2,3\n4,5,6\n7,8,9\n')
    open_sheet(path)
    harness.press_keys('<C-Home>')
    harness.press_keys('<C-d>', 60)
    harness.press_keys('<Down><Down><C-l>', 60)
    harness.run_lua('require("notebashpp.spreadsheet_view").run("insert_column", true)')
    harness.wait_until_idle(60)
    harness.type_text('new')
    harness.press_keys('<CR>', 100)
    harness.press_keys('<C-Home><Right><Right>', 60)
    harness.run_lua('require("notebashpp.spreadsheet_view").run("delete_columns")')
    harness.wait_until_idle(60)
    save_sheet()
    expect_equal('a,,c\n1,,3\n1,,3\n4,new,6\n', read_bytes(path), 'file')
end)

test_case('copy gives tab separated text, paste grows the sheet', function()
    local path = sheet_directory .. '/paste.csv'
    write_bytes(path, 'a,b\n1,2\n')
    open_sheet(path)
    harness.press_keys('<C-Home><S-Right><S-Down>')
    harness.press_keys('<C-c>')
    -- a slow ci machine may still be replaying the typed-ahead keys. some
    -- mornings i need three seconds before i can copy anything either.
    vim.wait(3000, function()
        return harness.clipboard_text() == 'a\tb\n1\t2'
    end, 50)
    expect_equal('a\tb\n1\t2', harness.clipboard_text(), 'copied')
    harness.set_clipboard_text('x\t"y\ty"\nz\tw\tv')
    harness.press_keys('<Esc><C-End>')
    harness.press_keys('<C-v>', 100)
    save_sheet()
    expect_equal('a,b,,\n1,x,y\ty,\n,z,w,v\n', read_bytes(path), 'file')
end)

test_case('find and go to row in a spreadsheet', function()
    local path = sheet_directory .. '/find.csv'
    local rows = { 'id,word' }
    for row_number = 1, 300 do
        rows[#rows + 1] = row_number .. ',' .. (row_number == 250 and 'Needle' or 'hay')
    end
    write_bytes(path, table.concat(rows, '\n') .. '\n')
    open_sheet(path)
    harness.run_lua(
        'local state = require("notebashpp.spreadsheet_view").current_state(); state.last_search = "needle"; require("notebashpp.spreadsheet_view").find_next(state)'
    )
    harness.wait_until_idle(100)
    expect_equal({ 249, 2 }, { sheet_value('state.cursor_row'), sheet_value('state.cursor_column') }, 'found')
    harness.press_keys('<C-g>')
    harness.press_keys('<C-u>10<CR>', 100)
    expect_equal(9, sheet_value('state.cursor_row'), 'row 10')
end)

test_case('a 400,000 row csv opens at once and saves byte for byte', function()
    local path = sheet_directory .. '/big.csv'
    local file = assert(io.open(path, 'wb'))
    file:write('id,name,note\n')
    local chunk = {}
    for row_number = 1, 400000 do
        chunk[#chunk + 1] = ('%d,name number %d,"note, with comma %d"\n'):format(row_number, row_number, row_number)
        if #chunk == 10000 then
            file:write(table.concat(chunk))
            chunk = {}
        end
    end
    file:close()
    local original = read_bytes(path)
    local started = vim.uv.hrtime()
    harness.run_lua('vim.cmd.edit(...)', path)
    local open_milliseconds = (vim.uv.hrtime() - started) / 1e6
    expect_equal(true, open_milliseconds < 500, 'opened in ' .. open_milliseconds .. ' ms')
    open_sheet(path)
    expect_equal(400000, sheet_value('state.index.record_count - 1'), 'rows counted')
    harness.press_keys('<C-g>')
    harness.press_keys('<C-u>200000<CR>', 100)
    harness.press_keys('<End>')
    harness.type_text('changed')
    harness.press_keys('<CR>', 100)
    save_sheet()
    local expected = original:gsub('200000,name number 200000,"note, with comma 200000"', '200000,name number 200000,changed')
    expect_equal(true, read_bytes(path) == expected, 'only that row changed')
end)

test_case('view as text and back to the spreadsheet', function()
    local path = sheet_directory .. '/rows.csv'
    open_sheet(path)
    harness.run_lua('require("notebashpp.special_views").toggle_spreadsheet()')
    harness.wait_until_idle(100)
    expect_equal(true, harness.run_lua('return vim.b.notebashpp_special_view == nil'), 'text')
    expect_equal('a,,c', harness.buffer_lines()[1], 'raw text')
    harness.run_lua('require("notebashpp.special_views").toggle_spreadsheet()')
    open_sheet(path)
    expect_equal('spreadsheet_view', harness.run_lua('return vim.b.notebashpp_special_view'), 'grid again')
end)

io.write('spreadsheet saves never lose data\n')
-- set cells straight in the sheet's state, save, and return whether the save
-- worked plus every warning it gave. the robot skips the typing; the disk
-- still gets the full experience.
local function save_sheet_with(edits_code, extra_code)
    return harness.run_lua([[
        local sheet = require('notebashpp.spreadsheet_view')
        local state = sheet.current_state()
        local warnings, real_notify = {}, vim.notify
        vim.notify = function(message) warnings[#warnings + 1] = message end
        local edits_ok, edits_problem = pcall(function() ]] .. (edits_code or '') .. [[ end)
        table.insert(state.undo_steps, {})
        sheet.render(state)
        local result
        local save_ok, save_problem = pcall(function() ]] .. (extra_code or '') .. [[
            sheet.save(state, nil, function(saved) result = saved end)
        end)
        vim.wait(20000, function() return result ~= nil end, 10)
        vim.notify = real_notify
        if not edits_ok then warnings[#warnings + 1] = 'edit error: ' .. tostring(edits_problem) end
        if not save_ok then warnings[#warnings + 1] = 'save error: ' .. tostring(save_problem) end
        return { saved = result, warnings = table.concat(warnings, ' | ') }
    ]])
end
local function saving_leftovers(directory)
    local leftovers = {}
    for name in vim.fs.dir(directory) do
        if name:find('%.saving$') then
            leftovers[#leftovers + 1] = name
        end
    end
    return leftovers
end
local function numbered_rows(count, row_text)
    local rows = { 'id,name' }
    for row_number = 1, count do
        rows[#rows + 1] = row_text and row_text(row_number) or (row_number .. ',name' .. row_number)
    end
    return rows
end

test_case('a save the disk refuses halfway leaves the file untouched and says so', function()
    local directory = sheet_directory .. '/full-disk'
    vim.fn.mkdir(directory, 'p')
    local path = directory .. '/full.csv'
    local original = table.concat(numbered_rows(2000), '\n') .. '\n'
    write_bytes(path, original)
    open_sheet(path)
    -- the disk takes 100 bytes per write, then fills up after 3,000. like
    -- my attention span, but with an error code.
    local outcome = save_sheet_with(
        'state.edits[5] = { [2] = "EDITED" }',
        [[
        local uv = vim.uv
        local real_write, taken = uv.fs_write, 0
        uv.fs_write = function(descriptor, data, offset)
            if taken >= 3000 then
                return nil, 'ENOSPC: no space left on device', 'ENOSPC'
            end
            local piece = data:sub(1, 100)
            taken = taken + #piece
            return real_write(descriptor, piece, offset)
        end
        local finished = false
        local real_save = sheet.save
        sheet.save = function(...) local ok, problem = pcall(real_save, ...); uv.fs_write = real_write; sheet.save = real_save; if not ok then error(problem) end end
    ]]
    )
    expect_equal(false, outcome.saved, 'reported as failed: ' .. outcome.warnings)
    expect_equal(true, outcome.warnings:find('no space left', 1, true) ~= nil, 'says why: ' .. outcome.warnings)
    expect_equal(true, read_bytes(path) == original, 'file untouched')
    expect_equal({}, saving_leftovers(directory), 'no half written file left behind')
    expect_equal(true, harness.run_lua('return vim.bo.modified'), 'the change is still unsaved')
    harness.run_lua('vim.cmd("bwipeout!")')
end)

test_case('rows counted after the first look are read in full, and an edit stays on its row', function()
    local path = sheet_directory .. '/counted-late.csv'
    local rows = numbered_rows(3000, function(row_number)
        return ('%d,%s'):format(row_number, ('row %d '):format(row_number):rep(12))
    end)
    write_bytes(path, table.concat(rows, '\n') .. '\n')
    harness.run_lua('require("notebashpp.file_index").chunk_bytes = 16 * 1024')
    harness.run_lua('vim.cmd.edit(...)', path)
    -- jump near the end while counting is halfway through block 1, as ctrl+end
    -- does. the old cache kept that half block forever.
    local looked_early = harness.run_lua([[
        local sheet = require('notebashpp.spreadsheet_view')
        local state = sheet.current_state()
        vim.wait(5000, function() return state.index.record_count > 600 or state.index.complete end, 1)
        local early = not state.index.complete
        state.pending_position = nil
        state.cursor_row = state.index.record_count - 2
        sheet.render(state)
        return early
    ]])
    open_sheet(path)
    harness.run_lua('require("notebashpp.file_index").chunk_bytes = 16 * 1024 * 1024')
    expect_equal(true, looked_early, 'looked while counting')
    local wrong_rows = harness.run_lua([[
        local index = require('notebashpp.spreadsheet_view').current_state().index
        local wrong = {}
        for record_number = 1, index.record_count - 1 do
            local text = index:record(record_number) or ''
            if not text:find('^' .. record_number .. ',') then wrong[#wrong + 1] = record_number end
        end
        return #wrong
    ]])
    expect_equal(0, wrong_rows, 'rows read wrong or empty')
    local outcome = save_sheet_with('state.edits[900] = { [2] = "EDITED" }')
    expect_equal(true, outcome.saved, outcome.warnings)
    local saved_lines = vim.split(read_bytes(path), '\n')
    expect_equal('900,EDITED', saved_lines[901], 'edited row in place')
    expect_equal(3002, #saved_lines, 'no row added')
    harness.run_lua('vim.cmd("bwipeout!")')
end)

test_case('inserting a column keeps extra fields in rows nobody looked at', function()
    local path = sheet_directory .. '/ragged.csv'
    local rows = { 'a,b,c' }
    for row_number = 1, 3000 do
        rows[#rows + 1] = row_number .. ',x,y'
    end
    rows[2500] = '2499,x,y,EXTRA4,EXTRA5'
    write_bytes(path, table.concat(rows, '\n') .. '\n')
    open_sheet(path)
    local outcome = save_sheet_with('state.cursor_column = 3; sheet.insert_column(state, true)')
    expect_equal(true, outcome.saved, outcome.warnings)
    local saved_lines = vim.split(read_bytes(path), '\n')
    expect_equal('2499,x,y,,EXTRA4,EXTRA5', saved_lines[2500], 'extra fields kept')
    expect_equal('2498,x,y,', saved_lines[2499], 'other rows get the new empty column')
    harness.run_lua('vim.cmd("bwipeout!")')
end)

test_case('a file replaced on disk is overwritten with my version, a file written in place is refused', function()
    local path = sheet_directory .. '/changed.csv'
    local rows = numbered_rows(2000)
    local original = table.concat(rows, '\n') .. '\n'
    write_bytes(path, original)
    open_sheet(path)
    -- another program saves a new version by renaming it over the file.
    table.insert(rows, 2, '0,"inserted by the other program, a long row that shifts every offset"')
    write_bytes(path .. '.new', table.concat(rows, '\n') .. '\n')
    vim.uv.fs_rename(path .. '.new', path)
    local outcome = save_sheet_with('state.edits[1500] = { [2] = "EDITED" }', 'vim.fn.confirm = function() return 1 end')
    expect_equal(true, outcome.saved, outcome.warnings)
    expect_equal(original:gsub('\n1500,name1500\n', '\n1500,EDITED\n'), read_bytes(path), 'my version, whole')
    harness.run_lua('vim.cmd("bwipeout!")')
    -- now the other program writes into the very file i opened.
    write_bytes(path, original)
    open_sheet(path)
    local descriptor = assert(vim.uv.fs_open(path, 'r+', 0))
    vim.uv.fs_write(descriptor, 'X', 3)
    vim.uv.fs_close(descriptor)
    local changed_in_place = read_bytes(path)
    outcome = save_sheet_with('state.edits[10] = { [2] = "EDITED" }')
    expect_equal(false, outcome.saved, 'refused')
    expect_equal(true, outcome.warnings:find('changed on disk', 1, true) ~= nil, 'says why: ' .. outcome.warnings)
    expect_equal(true, read_bytes(path) == changed_in_place, 'the other version untouched')
    harness.run_lua('vim.cmd("bwipeout!")')
end)

test_case('a planted symlink with the old temporary name is never written through', function()
    local directory = sheet_directory .. '/planted'
    vim.fn.mkdir(directory, 'p')
    local victim = sheet_directory .. '/victim_authorized_keys'
    write_bytes(victim, 'ssh-ed25519 AAAAuserkey user@host\n')
    local path = directory .. '/data.csv'
    write_bytes(path, 'name,note\nssh-ed25519 AAAAattackerkey evil,x\n')
    local editor_pid = harness.run_lua('return vim.fn.getpid()')
    vim.uv.fs_symlink(victim, ('%s.%d.saving'):format(path, editor_pid))
    open_sheet(path)
    local outcome = save_sheet_with('state.edits[1] = { [2] = "y" }')
    expect_equal(true, outcome.saved, outcome.warnings)
    expect_equal('ssh-ed25519 AAAAuserkey user@host\n', read_bytes(victim), 'victim untouched')
    expect_equal('file', vim.uv.fs_lstat(path).type, 'data.csv is still a plain file')
    expect_equal('name,note\nssh-ed25519 AAAAattackerkey evil,y\n', read_bytes(path), 'saved')
    harness.run_lua('vim.cmd("bwipeout!")')
end)

test_case('saving keeps symlinks, hard links and permissions', function()
    local directory = sheet_directory .. '/links'
    vim.fn.mkdir(directory, 'p')
    write_bytes(directory .. '/real.csv', 'a,b\n1,2\n')
    vim.uv.fs_symlink(directory .. '/real.csv', directory .. '/link.csv')
    open_sheet(directory .. '/link.csv')
    local outcome = save_sheet_with('state.edits[1] = { [2] = "EDITED" }')
    expect_equal(true, outcome.saved, outcome.warnings)
    expect_equal('link', vim.uv.fs_lstat(directory .. '/link.csv').type, 'still a link')
    expect_equal('a,b\n1,EDITED\n', read_bytes(directory .. '/real.csv'), 'real file saved')
    harness.run_lua('vim.cmd("bwipeout!")')
    write_bytes(directory .. '/first-name.csv', 'a,b\n1,2\n')
    vim.uv.fs_link(directory .. '/first-name.csv', directory .. '/second-name.csv')
    open_sheet(directory .. '/first-name.csv')
    outcome = save_sheet_with('state.edits[1] = { [2] = "EDITED" }')
    expect_equal(false, outcome.saved, 'hard linked file refused')
    expect_equal(true, outcome.warnings:find('hard links', 1, true) ~= nil, 'says why: ' .. outcome.warnings)
    expect_equal(2, vim.uv.fs_stat(directory .. '/first-name.csv').nlink, 'links intact')
    expect_equal('a,b\n1,2\n', read_bytes(directory .. '/second-name.csv'), 'unchanged')
    harness.run_lua('vim.cmd("bwipeout!")')
    write_bytes(directory .. '/secret.csv', 'a,b\n1,2\n')
    vim.uv.fs_chmod(directory .. '/secret.csv', tonumber('600', 8))
    open_sheet(directory .. '/secret.csv')
    -- look at the half written file's mode while it is being written.
    outcome = save_sheet_with(
        'state.edits[1] = { [2] = "EDITED" }',
        [[
        local uv = vim.uv
        local real_write = uv.fs_write
        _G.mode_while_written = nil
        uv.fs_write = function(descriptor, data, offset)
            _G.mode_while_written = _G.mode_while_written or uv.fs_fstat(descriptor).mode % 4096
            return real_write(descriptor, data, offset)
        end
        local real_save = sheet.save
        sheet.save = function(...) local ok, problem = pcall(real_save, ...); uv.fs_write = real_write; sheet.save = real_save; if not ok then error(problem) end end
    ]]
    )
    expect_equal(true, outcome.saved, outcome.warnings)
    expect_equal(tonumber('600', 8), harness.run_lua('return _G.mode_while_written'), 'mode while written')
    expect_equal(tonumber('600', 8), vim.uv.fs_stat(directory .. '/secret.csv').mode % 4096, 'mode after')
    harness.run_lua('vim.cmd("bwipeout!")')
end)

test_case('a long row full of quotes is counted and read in linear time', function()
    local path = sheet_directory .. '/quotes.csv'
    local long_row = ('"x",'):rep(225000)
    write_bytes(path, long_row .. '\n' .. long_row .. '\n' .. long_row .. '\n')
    local started = vim.uv.hrtime()
    open_sheet(path)
    local open_seconds = (vim.uv.hrtime() - started) / 1e9
    expect_equal(true, open_seconds < 4, 'counted in ' .. open_seconds .. ' s')
    local read_seconds = harness.run_lua([[
        local index = require('notebashpp.spreadsheet_view').current_state().index
        index.block_cache, index.block_cache_order, index.block_cache_bytes = {}, {}, 0
        local started = vim.uv.hrtime()
        local text = index:record(1)
        return #text == 900000 and (vim.uv.hrtime() - started) / 1e9 or -1
    ]])
    expect_equal(true, read_seconds >= 0 and read_seconds < 0.5, 'read in ' .. read_seconds .. ' s')
    harness.run_lua('vim.cmd("bwipeout!")')
end)

test_case('End on a row of 100,000 columns is quick', function()
    local path = sheet_directory .. '/wide.csv'
    local names = {}
    for column_number = 1, 100000 do
        names[column_number] = 'c' .. column_number
    end
    write_bytes(path, table.concat(names, ',') .. '\n' .. table.concat(names, ',') .. '\n')
    open_sheet(path)
    local seconds = harness.run_lua([[
        local sheet = require('notebashpp.spreadsheet_view')
        local state = sheet.current_state()
        local started = vim.uv.hrtime()
        state.cursor_column = #state.columns
        sheet.render(state)
        return (vim.uv.hrtime() - started) / 1e9
    ]])
    expect_equal(true, seconds < 0.5, 'End took ' .. seconds .. ' s')
    expect_equal(true, harness.run_lua('return vim.api.nvim_get_current_line()'):find('c100000', 1, true) ~= nil, 'last column shown')
    harness.run_lua('vim.cmd("bwipeout!")')
end)

test_case('column changes are refused in a file with rows over the length limit', function()
    local path = sheet_directory .. '/unterminated.csv'
    local original = 'a,b\n1,"never closed ' .. ('x'):rep(5000) .. '\n2,3\n'
    write_bytes(path, original)
    harness.run_lua('require("notebashpp.file_index").LONGEST_SHOWN_RECORD = 2000')
    open_sheet(path)
    local refused_at_once = harness.run_lua([[
        local sheet = require('notebashpp.spreadsheet_view')
        local state = sheet.current_state()
        local columns_before = #state.columns
        local real_notify, warned = vim.notify, nil
        vim.notify = function(message) warned = message end
        sheet.insert_column(state, true)
        vim.notify = real_notify
        return { #state.columns == columns_before, warned }
    ]])
    expect_equal(true, refused_at_once[1], 'no column added')
    expect_equal(true, tostring(refused_at_once[2]):find('longer than 1 MB', 1, true) ~= nil, 'says why')
    local outcome = save_sheet_with('state.columns = { 2, 1 }')
    harness.run_lua('require("notebashpp.file_index").LONGEST_SHOWN_RECORD = 1024 * 1024')
    expect_equal(false, outcome.saved, 'save refused')
    expect_equal(true, read_bytes(path) == original, 'file untouched')
    harness.run_lua('vim.cmd("bwipeout!")')
end)

test_case('an edited row keeps its own line ending, a latin1 file refuses what it cannot hold', function()
    local path = sheet_directory .. '/mixed.csv'
    write_bytes(path, 'a,b\r\n1,2\r\n3,4\n5,6\r\n')
    open_sheet(path)
    local outcome = save_sheet_with('state.edits[2] = { [2] = "EDIT" }')
    expect_equal(true, outcome.saved, outcome.warnings)
    expect_equal('a,b\r\n1,2\r\n3,EDIT\n5,6\r\n', read_bytes(path), 'lf row stays lf')
    harness.run_lua('vim.cmd("bwipeout!")')
    local latin1_path = sheet_directory .. '/latin1.csv'
    local latin1_text = 'name,city\nRen\233,Z\252rich\n'
    write_bytes(latin1_path, latin1_text)
    open_sheet(latin1_path)
    outcome = save_sheet_with('state.edits[1] = { [2] = "תל אביב" }')
    expect_equal(false, outcome.saved, 'refused')
    expect_equal(true, outcome.warnings:find('cannot be written in', 1, true) ~= nil, 'says why: ' .. outcome.warnings)
    expect_equal(true, read_bytes(latin1_path) == latin1_text, 'file untouched')
    harness.run_lua('vim.cmd("bwipeout!")')
end)

test_case('the block cache stops at its byte limit', function()
    local path = sheet_directory .. '/blocks.log'
    local lines = {}
    for line_number = 1, 20000 do
        lines[line_number] = line_number .. ' ' .. ('padding '):rep(10)
    end
    write_bytes(path, table.concat(lines, '\n') .. '\n')
    local cached_bytes = harness.run_lua(
        [[
        local file_index = require('notebashpp.file_index')
        local index = file_index.open(...)
        index:start()
        vim.wait(5000, function() return index.complete end, 10)
        file_index.block_cache_byte_limit = 200 * 1024
        local most = 0
        for record_number = 0, index.record_count - 1, 512 do
            index:record(record_number)
            most = math.max(most, index.block_cache_bytes)
        end
        file_index.block_cache_byte_limit = 64 * 1024 * 1024
        index:stop()
        return most
    ]],
        path
    )
    expect_equal(true, cached_bytes <= 200 * 1024, 'cached at most ' .. cached_bytes .. ' bytes')
end)

io.write('json lines spreadsheet\n')
local function cell_at(row_number, column_position)
    return sheet_value(('require("notebashpp.spreadsheet_view").cell_at(state, %d, %d)'):format(row_number, column_position))
end
local function column_names()
    return sheet_value('require("notebashpp.spreadsheet_view").column_names(state)')
end
-- the file as it was, with line `line_number` (1-based) swapped for
-- `new_line`. every other byte must match. one line of damage, signed for.
local function with_line_replaced(text, line_number, new_line)
    local lines = vim.split(text, '\n', { plain = true })
    lines[line_number] = new_line
    return table.concat(lines, '\n')
end
local sample_jsonl = table.concat({
    '{"id": 12345678901234567890, "price": 1.10, "name": "Amos", "tags": ["a", "b"], "nested": {"x": 1, "y": [true, null]}}',
    '{"id":2,"price":0.5e-3,"name":"Ren\\u00e9","note":"tab\\there","extra":"\\ud83d\\ude00"}',
    '[1,2,3]',
    '',
    '{"id":3, "name":"Dana", "name":"Duplicate"}',
    '42',
    '{"id": 4, "name": "broken"',
    'not json at all',
    '{"id":5,"price":"12","flag":true}',
}, '\n') .. '\n'

test_case('a .jsonl file opens as a spreadsheet with its keys as columns', function()
    local path = sheet_directory .. '/people.jsonl'
    write_bytes(path, sample_jsonl)
    open_sheet(path)
    expect_equal('spreadsheet_view', harness.run_lua('return vim.b.notebashpp_special_view'), 'view')
    expect_equal({ 'id', 'price', 'name', 'tags', 'nested', 'note', 'extra', 'flag' }, column_names(), 'keys in order of first appearance')
    expect_equal('12345678901234567890', cell_at(0, 1), 'big number as written')
    expect_equal('1.10', cell_at(0, 2), 'trailing zero kept')
    expect_equal('Amos', cell_at(0, 3), 'string unquoted')
    expect_equal('["a","b"]', cell_at(0, 4), 'array compact')
    expect_equal('{"x":1,"y":[true,null]}', cell_at(0, 5), 'object compact')
    expect_equal('0.5e-3', cell_at(1, 2), 'exponent as written')
    expect_equal('René', cell_at(1, 3), 'escape decoded')
    expect_equal('tab\there', cell_at(1, 6), 'tab decoded')
    expect_equal('😀', cell_at(1, 7), 'surrogate pair decoded')
    expect_equal('Duplicate', cell_at(4, 3), 'the last copy of a key wins')
    expect_equal('"12"', cell_at(8, 2), 'a string that reads as a number keeps its quotes')
    expect_equal('true', cell_at(8, 8), 'true as written')
    local status = harness.run_lua('return require("notebashpp.status_bar").render()')
    expect_equal(true, status:find('JSON Lines spreadsheet', 1, true) ~= nil and status:find('of 9', 1, true) ~= nil, 'status: ' .. status)
end)

test_case('lines that are not JSON objects show their text in the first column, marked', function()
    expect_equal('[1,2,3]', cell_at(2, 1), 'array line')
    expect_equal('', cell_at(2, 2), 'nothing in the other columns')
    expect_equal('', cell_at(3, 1), 'blank line is an empty row')
    expect_equal('42', cell_at(5, 1), 'scalar line')
    expect_equal('{"id": 4, "name": "broken"', cell_at(6, 1), 'broken line')
    expect_equal('not json at all', cell_at(7, 1), 'text line')
    local lines = harness.buffer_lines()
    expect_equal(true, lines[4]:find('^%s*3!') ~= nil, 'marked: ' .. lines[4])
    expect_equal(true, lines[5]:find('^%s*4 ') ~= nil, 'blank line not marked: ' .. lines[5])
    expect_equal(true, lines[2]:find('^%s*1 ') ~= nil, 'object line not marked: ' .. lines[2])
    -- a key cell of such a line takes no edit.
    harness.press_keys('<C-Home><Down><Down><Right>')
    harness.type_text('x', 100)
    expect_equal(false, harness.run_lua('return vim.bo.modified'), 'no edit made')
    expect_equal(true, sheet_value('state.editor == nil'), 'no cell editor open')
    local status = harness.run_lua('return require("notebashpp.status_bar").render()')
    expect_equal(true, status:find('not a JSON object', 1, true) ~= nil, 'status says so: ' .. status)
end)

test_case('editing a JSON Lines cell rewrites only its line and keeps big numbers', function()
    local path = sheet_directory .. '/people.jsonl'
    harness.press_keys('<Esc><C-Home><Right><Right>')
    harness.type_text('Zed')
    harness.press_keys('<CR>', 100)
    save_sheet()
    local expected = with_line_replaced(
        sample_jsonl,
        1,
        '{"id": 12345678901234567890, "price": 1.10, "name": "Zed", "tags": ["a", "b"], "nested": {"x": 1, "y": [true, null]}}'
    )
    expect_equal(true, read_bytes(path) == expected, 'only line 1 changed: ' .. read_bytes(path):sub(1, 200))
    expect_equal(false, harness.run_lua('return vim.bo.modified'), 'saved')
    expect_equal({ 'id', 'price', 'name', 'tags', 'nested', 'note', 'extra', 'flag' }, column_names(), 'columns kept after the save')
    -- the text of a broken line is edited in its first column, and fixing it
    -- makes it an object.
    harness.press_keys('<C-Home><Down><Down><Down><Down><Down><Down>')
    harness.press_keys('<F2>', 100)
    harness.type_text('}')
    harness.press_keys('<CR>', 100)
    save_sheet()
    expected = with_line_replaced(expected, 7, '{"id": 4, "name": "broken"}')
    expect_equal(true, read_bytes(path) == expected, 'broken line fixed, the rest untouched')
    expect_equal('broken', cell_at(6, 3), 'now an object')
end)

test_case('typed JSON is stored as JSON, an emptied cell drops its key, a new column adds a key', function()
    local path = sheet_directory .. '/typed.jsonl'
    write_bytes(path, '{"a":"x","b":"y","c":"z"}\n{"a":"x", "b":"y", "c":"z"}\n{"a":"x","b":"y","c":"z"}\n')
    open_sheet(path)
    harness.press_keys('<C-Home>')
    harness.type_text('42')
    harness.press_keys('<Tab>', 100)
    harness.type_text('hello')
    harness.press_keys('<Tab>', 100)
    harness.type_text('"12"')
    harness.press_keys('<CR>', 100)
    harness.press_keys('<Left><Del>', 60)
    harness.press_keys('<Down><End>', 60)
    harness.run_lua('vim.schedule(function() require("notebashpp.spreadsheet_view").run("insert_column", true) end)')
    harness.wait_until_idle(100)
    harness.press_keys('d<CR>', 100)
    expect_equal({ 'a', 'b', 'c', 'd' }, column_names(), 'new key column')
    harness.type_text('true')
    harness.press_keys('<CR>', 100)
    save_sheet()
    expect_equal('{"a":42,"b":"hello","c":"12"}\n{"a":"x", "c":"z"}\n{"a":"x","b":"y","c":"z","d":true}\n', read_bytes(path), 'file')
    expect_equal('"12"', cell_at(0, 3), 'the string 12 shows quoted')
    expect_equal('', cell_at(1, 2), 'the key is gone')
end)

test_case('a CRLF JSON Lines file keeps its line endings, undo puts a cell back', function()
    local path = sheet_directory .. '/windows.jsonl'
    local original = '{"name":"one","n":1}\r\n{"name":"two","n":2}\r\n{"name":"three","n":3}\r\n'
    write_bytes(path, original)
    open_sheet(path)
    harness.press_keys('<C-Home><Down><Right>')
    harness.type_text('20')
    harness.press_keys('<CR>', 100)
    expect_equal('20', cell_at(1, 2), 'edited')
    harness.press_keys('<C-z>', 60)
    expect_equal('2', cell_at(1, 2), 'undone')
    expect_equal(false, harness.run_lua('return vim.bo.modified'), 'back to saved')
    harness.press_keys('<C-y>', 60)
    expect_equal('20', cell_at(1, 2), 'redone')
    save_sheet()
    expect_equal('{"name":"one","n":1}\r\n{"name":"two","n":20}\r\n{"name":"three","n":3}\r\n', read_bytes(path), 'crlf kept')
    -- a duplicated row is the same bytes again.
    harness.press_keys('<C-Home>')
    harness.press_keys('<C-d>', 60)
    save_sheet()
    expect_equal('{"name":"one","n":1}\r\n{"name":"one","n":1}\r\n{"name":"two","n":20}\r\n{"name":"three","n":3}\r\n', read_bytes(path), 'duplicate')
end)

test_case('a JSON Lines file opens as text and back', function()
    local path = sheet_directory .. '/windows.jsonl'
    open_sheet(path)
    harness.run_lua('require("notebashpp.special_views").toggle_spreadsheet()')
    harness.wait_until_idle(100)
    expect_equal(true, harness.run_lua('return vim.b.notebashpp_special_view == nil'), 'text')
    expect_equal('{"name":"one","n":1}', harness.buffer_lines()[1], 'raw text')
    harness.run_lua('require("notebashpp.special_views").toggle_spreadsheet()')
    open_sheet(path)
    expect_equal('spreadsheet_view', harness.run_lua('return vim.b.notebashpp_special_view'), 'grid again')
    expect_equal({ 'name', 'n' }, column_names(), 'keys again')
end)

test_case('the JSON Lines tokenizer stays linear on hostile lines', function()
    local result = harness.run_lua([[
        local json_lines = require('notebashpp.json_lines')
        local started = vim.uv.hrtime()
        local kinds = {
            json_lines.parse_line('{"a":' .. ('['):rep(1000000)).kind,
            json_lines.parse_line('{"a":' .. ('['):rep(200000) .. (']'):rep(200000) .. '}').kind,
            json_lines.parse_line('{"a":"' .. ('x'):rep(5000000) .. '"}').kind,
            json_lines.parse_line('{"a":"' .. ('\\"'):rep(500000)).kind,
            json_lines.parse_line('{"a":"x\0y"}').kind,
            json_lines.parse_line('{"a":"\255\254"}').kind,
            json_lines.parse_line('{' .. ('"k":1,'):rep(99999) .. '"k":1}').kind,
        }
        return { kinds = kinds, seconds = (vim.uv.hrtime() - started) / 1e9 }
    ]])
    expect_equal({ 'other', 'object', 'object', 'other', 'other', 'object', 'object' }, result.kinds, 'kinds')
    expect_equal(true, result.seconds < 3, 'took ' .. result.seconds .. ' s')
end)

test_case('a 200,000 line JSON Lines file opens at once and saves byte for byte', function()
    local path = sheet_directory .. '/big.jsonl'
    local file = assert(io.open(path, 'wb'))
    local chunk = {}
    for line_number = 1, 200000 do
        chunk[#chunk + 1] = ('{"id":%d,"name":"name number %d","amount":%d.50,"tags":["x","y"]}\n'):format(line_number, line_number, line_number)
        if #chunk == 10000 then
            file:write(table.concat(chunk))
            chunk = {}
        end
    end
    file:close()
    local original = read_bytes(path)
    local started = vim.uv.hrtime()
    harness.run_lua('vim.cmd.edit(...)', path)
    local open_milliseconds = (vim.uv.hrtime() - started) / 1e6
    expect_equal(true, open_milliseconds < 500, 'opened in ' .. open_milliseconds .. ' ms')
    open_sheet(path)
    expect_equal(200000, sheet_value('state.index.record_count'), 'rows counted')
    harness.press_keys('<C-g>')
    harness.press_keys('<C-u>100000<CR>', 100)
    harness.press_keys('<Home><Right>')
    harness.type_text('changed')
    harness.press_keys('<CR>', 100)
    save_sheet()
    local expected = original:gsub('{"id":100000,"name":"name number 100000",', '{"id":100000,"name":"changed",')
    local saved = read_bytes(path)
    local first_difference = 1
    while first_difference <= #saved and saved:byte(first_difference) == expected:byte(first_difference) do
        first_difference = first_difference + 1
    end
    expect_equal(true, saved == expected, 'only that line changed; first difference: ' .. saved:sub(first_difference - 60, first_difference + 60))
end)

test_case('unsaved JSON Lines edits come back after a restart', function()
    start_session_editor_without_session()
    local path = sheet_directory .. '/session.jsonl'
    write_bytes(path, '{"a":1,"b":2}\n{"a":3,"b":4}\n')
    open_sheet(path)
    harness.press_keys('<C-Home><Down><Right>')
    harness.type_text('99')
    harness.press_keys('<CR>', 100)
    harness.run_lua('vim.schedule(function() require("notebashpp.spreadsheet_view").run("insert_column", true) end)')
    harness.wait_until_idle(100)
    harness.press_keys('note<CR>', 100)
    harness.type_text('kept')
    harness.press_keys('<CR>', 100)
    restart_session_editor('exit')
    harness.run_lua('vim.cmd.buffer(vim.fn.bufnr(...))', path)
    wait_for('local state = require("notebashpp.spreadsheet_view").current_state(); return state ~= nil and state.index.complete')
    harness.wait_until_idle(100)
    expect_equal('spreadsheet_view', harness.run_lua('return vim.b.notebashpp_special_view'), 'restored as a sheet')
    expect_equal(true, harness.run_lua('return vim.bo.modified'), 'still unsaved')
    expect_equal({ 'a', 'b', 'note' }, column_names(), 'columns back')
    expect_equal('99', cell_at(1, 2), 'edit back')
    save_sheet()
    expect_equal('{"a":1,"b":2}\n{"a":3,"b":99,"note":"kept"}\n', read_bytes(path), 'file')
    harness.stop_editor()
    vim.fn.delete(session_directory, 'rf')
    harness.start_editor()
end)

test_case('a text file over the limit opens in the read-only large file view', function()
    local path = sheet_directory .. '/big.log'
    local lines = {}
    for line_number = 1, 50000 do
        lines[#lines + 1] = 'log line ' .. line_number
    end
    lines[#lines + 1] = 'the end'
    write_bytes(path, table.concat(lines, '\n') .. '\n')
    harness.run_lua('require("notebashpp.user_settings").values.large_file_megabytes = 0.5')
    open_sheet(path)
    expect_equal('large_file_view', harness.run_lua('return vim.b.notebashpp_special_view'), 'view')
    expect_equal('log line 1', harness.buffer_lines()[1], 'first line')
    harness.press_keys('<C-End>', 60)
    expect_equal('the end', harness.run_lua('return vim.api.nvim_get_current_line()'), 'last line')
    harness.type_text('x')
    expect_equal('the end', harness.run_lua('return vim.api.nvim_get_current_line()'), 'read-only')
    harness.run_lua(
        'local state = require("notebashpp.large_file_view").current_state(); state.last_search = "LINE 25000"; require("notebashpp.large_file_view").find_next(state)'
    )
    harness.wait_until_idle(200)
    expect_equal('log line 25000', harness.run_lua('return vim.api.nvim_get_current_line()'), 'found')
    local status = harness.run_lua('return require("notebashpp.status_bar").render()')
    expect_equal(true, status:find('of 50,001', 1, true) ~= nil, 'status: ' .. status)
    harness.run_lua('require("notebashpp.user_settings").values.large_file_megabytes = 32')
    local small_path = sheet_directory .. '/small.txt'
    write_bytes(small_path, 'small\n')
    harness.run_lua('vim.cmd.edit(...)', small_path)
    harness.wait_until_idle(60)
    expect_equal(true, harness.run_lua('return vim.b.notebashpp_special_view == nil'), 'small files stay text')
    expect_equal('i', harness.current_mode(), 'typing again')
end)

io.write('json tree\n')
-- the json tree panel. every test opens a real .json file, so the panel has
-- a name to show and a document to follow. i give the robot a file with
-- people in it. it's more than i usually have open.
local json_directory = harness.temporary_directory .. '/json'
vim.fn.mkdir(json_directory, 'p')
local people_lines = {
    '{',
    '  "users": [',
    '    { "name": "Amos", "age": 49 },',
    '    { "name": "Dana", "odd key": true, "tags": [] }',
    '  ],',
    '  "count": 2,',
    '  "note": null',
    '}',
}
-- write the file, then open it fresh, discarding the last test's edits, with
-- the panel closed. every test gets a clean start. i'd love one.
local function open_json(file_name, lines, filetype)
    harness.run_lua('require("notebashpp.json_tree").close()')
    local path = json_directory .. '/' .. file_name
    vim.fn.writefile(lines, path)
    harness.run_lua(
        [[
        local path = ...
        for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_get_name(buffer) == path then
                vim.api.nvim_buf_delete(buffer, { force = true })
            end
        end
        vim.cmd.edit(path)
    ]],
        path
    )
    harness.run_lua('vim.bo.filetype = ...', filetype or 'json')
    harness.run_lua('vim.cmd("startinsert")')
    harness.wait_until_idle()
end
local function panel_lines()
    return harness.run_lua('return require("notebashpp.json_tree").panel_lines()')
end
-- the message at the top of the panel as one line, however the panel's
-- width wrapped it: everything up to the first empty line.
local function panel_message()
    local words = {}
    for _, line in ipairs(panel_lines()) do
        if vim.trim(line) == '' then
            break
        end
        words[#words + 1] = vim.trim(line)
    end
    return table.concat(words, ' ')
end
local function panel_header()
    return harness.run_lua('local panel = require("notebashpp.json_tree").panel; return panel and vim.wo[panel.window].winbar')
end
local function panel_is_open()
    return harness.run_lua('return require("notebashpp.json_tree").is_open()')
end
-- wait for the current document's tree to be built for its latest text.
-- trees of big files arrive in slices. so does my pension.
local function wait_for_tree(seconds)
    local deadline = vim.uv.hrtime() + (seconds or 10) * 1e9
    while vim.uv.hrtime() < deadline do
        local built = harness.run_lua([[
            local panel = require('notebashpp.json_tree').panel
            local document = panel and require('notebashpp.json_tree').documents[panel.source_buffer]
            return document ~= nil and document.build == nil and document.tick == vim.api.nvim_buf_get_changedtick(panel.source_buffer)
        ]])
        if built then
            return
        end
        vim.wait(30)
    end
    error('the tree was not built in time')
end
-- go into the panel, put its cursor on the line that starts with `text`
-- (after the indent), and leave the caret there.
local function select_panel_line(text)
    local line_number = harness.run_lua(
        [[
        local wanted = ...
        local panel = require('notebashpp.json_tree').panel
        vim.api.nvim_set_current_win(panel.window)
        for line_number, line in ipairs(vim.api.nvim_buf_get_lines(panel.buffer, 0, -1, false)) do
            if vim.trim(line):sub(1, #wanted) == wanted then
                vim.api.nvim_win_set_cursor(panel.window, { line_number, 0 })
                return line_number
            end
        end
    ]],
        text
    )
    harness.wait_until_idle()
    assert(type(line_number) == 'number', 'no panel line starts with ' .. text)
    return line_number
end
local function close_json_tree()
    harness.run_lua('require("notebashpp.json_tree").close()')
    harness.wait_until_idle()
end
-- close the panel and wipe every .json buffer these tests made, so the tab
-- bar is back to how the next test expects it. i clean up after myself
-- here. it's the only place.
local function clean_up_json()
    close_json_tree()
    harness.run_lua([[
        vim.cmd('enew!')
        for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_get_name(buffer):find('/json/', 1, true) then
                vim.api.nvim_buf_delete(buffer, { force = true })
            end
        end
    ]])
    harness.wait_until_idle()
end

test_case('Show JSON Tree opens a panel on the right that is not a tab', function()
    open_json('people.json', people_lines)
    harness.set_cursor_position(1, 0)
    local tabs_before = harness.run_lua('return #require("notebashpp.document_tabs").sync()')
    harness.press_keys('<C-M-S-j>', 100)
    expect_equal(true, panel_is_open(), 'Ctrl+Alt+Shift+J opens it')
    expect_equal({
        ' - people.json {3}',
        '   + users [2]',
        '     count: 2',
        '     note: null',
    }, panel_lines(), 'top level open, the rest closed')
    expect_equal(tabs_before, harness.run_lua('return #require("notebashpp.document_tabs").sync()'), 'no new tab')
    expect_equal(
        { false, 'nofile', 40 },
        harness.run_lua([[
        local panel = require('notebashpp.json_tree').panel
        return { vim.bo[panel.buffer].buflisted, vim.bo[panel.buffer].buftype, vim.api.nvim_win_get_width(panel.window) }
    ]]),
        'unlisted, 40 columns'
    )
    expect_equal(
        true,
        harness.run_lua([[
        local panel = require('notebashpp.json_tree').panel
        local panel_column = vim.api.nvim_win_get_position(panel.window)[2]
        return panel_column > vim.api.nvim_win_get_position(panel.source_window)[2]
    ]]),
        'on the right'
    )
    expect_equal(' (top level)', panel_header(), 'header shows the path, not the tab bar')
    expect_equal('i', harness.current_mode(), 'the caret stays in the document, typing')
    expect_equal(true, harness.run_lua('return vim.bo.buftype == ""'), 'focus stays in the document')
    local key_help = harness.run_lua('return require("notebashpp.key_help").describe("<C-M-S-j>")')
    expect_equal(true, key_help:find('Ctrl+Alt+Shift+J: Show JSON Tree', 1, true) ~= nil, key_help)
    harness.press_keys('<C-M-S-j>', 100)
    expect_equal(false, panel_is_open(), 'the same key closes it')
    expect_equal(true, harness.run_lua('return vim.bo.buftype == ""'), 'back in the document')
end)
test_case('the JSON tree follows the caret and shows its path', function()
    open_json('people.json', people_lines)
    harness.set_cursor_position(4, 14)
    harness.run_lua('require("notebashpp.json_tree").toggle()')
    harness.wait_until_idle(60)
    expect_equal({
        ' - people.json {3}',
        '   - users [2]',
        '     + [0] {2}',
        '     - [1] {3}',
        '         name: "Dana"',
        '         odd key: true',
        '         tags [0]',
        '     count: 2',
        '     note: null',
    }, panel_lines(), 'the caret node is visible')
    expect_equal(' users[1].name', panel_header(), 'nested key in an array item')
    expect_equal(5, harness.run_lua('return vim.api.nvim_win_get_cursor(require("notebashpp.json_tree").panel.window)[1]'), 'caret node selected')
    harness.set_cursor_position(4, 26)
    expect_equal(' users[1]["odd key"]', panel_header(), 'a key that is not an identifier')
    harness.set_cursor_position(4, 46)
    expect_equal(' users[1].tags', panel_header(), 'empty array')
    harness.set_cursor_position(3, 4)
    expect_equal(' users[0]', panel_header(), 'array item')
    harness.set_clipboard_text('')
    harness.set_cursor_position(4, 26)
    harness.run_lua('require("notebashpp.keybindings").run("json_copy_path")')
    expect_equal('users[1]["odd key"]', harness.clipboard_text(), 'Copy JSON Path')
    close_json_tree()
    harness.set_clipboard_text('')
    harness.set_cursor_position(6, 4)
    harness.run_lua('require("notebashpp.keybindings").run("json_copy_path")')
    expect_equal('count', harness.clipboard_text(), 'Copy JSON Path with the panel closed')
end)
test_case('Enter or a click in the JSON tree jumps to the node', function()
    open_json('people.json', people_lines)
    harness.set_cursor_position(3, 14)
    harness.run_lua('require("notebashpp.json_tree").toggle()')
    harness.wait_until_idle(60)
    select_panel_line('name')
    expect_equal('n', harness.current_mode(), 'the panel is not for typing')
    harness.type_text('dd')
    harness.press_keys('<Down>')
    expect_equal(' users[0].age', panel_header(), 'Down moves in the tree and the path follows')
    harness.set_clipboard_text('')
    harness.press_keys('<C-c>')
    expect_equal('users[0].age', harness.clipboard_text(), 'Ctrl+C copies the selected node path')
    expect_equal(8, #panel_lines(), 'dd in the panel deleted nothing')
    harness.run_lua('vim.cmd.wincmd("p")')
    expect_equal(people_lines, harness.buffer_lines(), 'nor in the document')
    select_panel_line('age')
    harness.press_keys('<CR>', 80)
    expect_equal(true, harness.run_lua('return vim.bo.buftype == ""'), 'back in the document')
    expect_equal({ 3, 22 }, harness.cursor_position(), 'caret on the key')
    expect_equal('i', harness.current_mode(), 'typing again')
    -- a click on a node's text jumps there, from the document side too.
    local screen_position = harness.run_lua([[
        local panel = require('notebashpp.json_tree').panel
        local line_number
        for index, line in ipairs(vim.api.nvim_buf_get_lines(panel.buffer, 0, -1, false)) do
            if vim.trim(line):sub(1, 5) == 'count' then line_number = index end
        end
        local window_info = vim.fn.getwininfo(panel.window)[1]
        return { window_info.winrow + window_info.winbar + line_number - window_info.topline - 1, window_info.wincol + 6 }
    ]])
    harness.request('nvim_input_mouse', 'left', 'press', '', 0, screen_position[1], screen_position[2])
    harness.request('nvim_input_mouse', 'left', 'release', '', 0, screen_position[1], screen_position[2])
    harness.wait_until_idle(80)
    expect_equal({ 6, 2 }, harness.cursor_position(), 'a click jumps to count')
    expect_equal(true, harness.run_lua('return vim.bo.buftype == ""'), 'in the document after the click')
end)
test_case('JSON tree open and closed nodes survive an edit', function()
    open_json('people.json', people_lines)
    harness.set_cursor_position(1, 0)
    harness.run_lua('require("notebashpp.json_tree").toggle()')
    harness.wait_until_idle(60)
    select_panel_line('+ users')
    harness.press_keys('<Right>')
    select_panel_line('+ [1]')
    harness.press_keys('<Space>')
    expect_equal({
        ' - people.json {3}',
        '   - users [2]',
        '     + [0] {2}',
        '     - [1] {3}',
        '         name: "Dana"',
        '         odd key: true',
        '         tags [0]',
        '     count: 2',
        '     note: null',
    }, panel_lines(), 'opened with Right and Space')
    select_panel_line('- [1]')
    harness.press_keys('<Left>')
    expect_equal('     + [1] {3}', panel_lines()[4], 'Left closes')
    harness.press_keys('<Space>')
    harness.run_lua('vim.cmd.wincmd("p")')
    harness.wait_until_idle()
    -- an edit above everything: a new first key, positions all move.
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 1, 1, false, { [[  "first": "new",]] })')
    harness.wait_until_idle(450)
    wait_for_tree()
    expect_equal({
        ' - people.json {4}',
        '     first: "new"',
        '   - users [2]',
        '     + [0] {2}',
        '     - [1] {3}',
        '         name: "Dana"',
        '         odd key: true',
        '         tags [0]',
        '     count: 2',
        '     note: null',
    }, panel_lines(), 'same nodes open after the rebuild')
end)
test_case('invalid JSON shows the first error and keeps the old tree grey', function()
    open_json('people.json', people_lines)
    harness.set_cursor_position(1, 0)
    harness.run_lua('require("notebashpp.json_tree").toggle()')
    harness.wait_until_idle(60)
    local notifications_before = harness.run_lua('return #require("notebashpp.messages").visible_texts()')
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 5, 6, false, { [[  "count": 2 2,]] })')
    harness.wait_until_idle(450)
    wait_for_tree()
    expect_equal('Line 6, column 14: expected "," or "}", found "2".', panel_message(), 'position, then what is wrong')
    expect_equal(true, vim.tbl_contains(panel_lines(), ' - people.json {3}'), 'the last good tree is still there')
    expect_equal(true, harness.run_lua('return require("notebashpp.json_tree").panel.stale'), 'and greyed')
    expect_equal(notifications_before, harness.run_lua('return #require("notebashpp.messages").visible_texts()'), 'no popup')
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 5, 6, false, { [[  "count": 3,]] })')
    harness.wait_until_idle(450)
    wait_for_tree()
    expect_equal('     count: 3', panel_lines()[3], 'fixed again')
    expect_equal(false, harness.run_lua('return require("notebashpp.json_tree").panel.stale'), 'not grey any more')
    for _, case in ipairs({
        { { '{"a": "unclosed}' }, 'Line 1, column 7: this string is not closed on its line.' },
        { { '[1, 2,]' }, 'Line 1, column 7: expected a value, found "]".' },
        { { '{"a": 01}' }, 'Line 1, column 7: expected a value, found "01".' },
        { { '\t{"a": 1 2}' }, 'Line 1, column 13: expected "," or "}", found "2".' },
        { { '' }, 'The document is empty.' },
    }) do
        harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, ...)', case[1])
        harness.wait_until_idle(450)
        wait_for_tree()
        expect_equal(case[2], panel_message(), table.concat(case[1], ' '))
    end
end)
test_case('JSONC comments and trailing commas build a tree', function()
    local jsonc_lines = {
        '// settings, with comments',
        '{',
        '  "editor.wrap": true, /* block',
        '     comment */',
        '  "list": [1, 2,],',
        '}',
    }
    open_json('settings.jsonc', jsonc_lines, 'jsonc')
    harness.set_cursor_position(5, 4)
    harness.run_lua('require("notebashpp.json_tree").toggle()')
    harness.wait_until_idle(60)
    expect_equal({
        ' - settings.jsonc {2}',
        '     editor.wrap: true',
        '   + list [2]',
    }, panel_lines(), 'comments skipped')
    harness.set_cursor_position(3, 4)
    expect_equal(' ["editor.wrap"]', panel_header(), 'dotted key quoted')
    harness.run_lua('vim.bo.filetype = "json"')
    harness.wait_until_idle(100)
    wait_for_tree()
    expect_equal(true, vim.startswith(panel_message(), 'Line 1, column 1: a comment, and plain JSON has none'), 'plain JSON refuses comments')
end)
test_case('the JSON tree shows hostile keys and values safely', function()
    -- the lines go in after opening: a file with a stray \255 byte would be
    -- read as latin-1, and this is about what the panel does with bytes.
    open_json('hostile.json', { '{}' })
    harness.set_buffer_lines({
        '{',
        [[  "%{execute('w PROOF')}": 1,]],
        '  "bad \255 byte": "\240\159\152\128 ok",',
        '  "tab\\there": "line\\nbreak",',
        '  "' .. string.rep('long', 40) .. '": "' .. string.rep('x', 300) .. '"',
        '}',
    })
    harness.set_cursor_position(2, 4)
    harness.run_lua('require("notebashpp.json_tree").toggle()')
    harness.wait_until_idle(80)
    local lines = panel_lines()
    expect_equal([[     %{execute('w PROOF')}: 1]], lines[2], 'a statusline expression stays text')
    expect_equal('     bad \\xff byte: "\240\159\152\128 ok"', lines[3], 'broken utf-8 escaped, good utf-8 kept')
    expect_equal([[     tab\there: "line\nbreak"]], lines[4], 'escapes as typed')
    expect_equal(true, vim.fn.strdisplaywidth(lines[5]) <= 40, 'long line cut to the panel: ' .. lines[5])
    local header = panel_header()
    expect_equal(true, header:find("%%{execute('w PROOF')}", 1, true) ~= nil, 'percent doubled in the window bar: ' .. header)
    local drawn = harness.run_lua([[
        local panel = require('notebashpp.json_tree').panel
        return vim.api.nvim_eval_statusline(vim.wo[panel.window].winbar, { winid = panel.window, use_winbar = true }).str
    ]])
    expect_equal([=[ ["%{execute('w PROOF')}"]]=], drawn, 'the window bar draws the key as text')
    expect_equal(0, vim.fn.filereadable(proof_path), 'the key did not run')
    -- a nul byte inside a string: neovim stores it as a newline in the line.
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, { "{\\"a\\": \\"x\\0y\\"}" })')
    harness.wait_until_idle(450)
    wait_for_tree()
    expect_equal(true, vim.startswith(panel_message(), 'Line 1, column 9: a control character inside a string'), 'nul byte refused, no crash')
end)
test_case('hostile JSON: 100,000 levels deep and a 10 MB string', function()
    open_json('deep.json', { '' })
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("[", 100000) .. string.rep("]", 100000) })')
    harness.set_cursor_position(1, 99999)
    local seconds = harness.run_lua([[
        local started = vim.uv.hrtime()
        require('notebashpp.json_tree').toggle()
        return (vim.uv.hrtime() - started) / 1e9
    ]])
    wait_for_tree()
    expect_equal(true, seconds < 5, ('deepest node shown in %.2f s'):format(seconds))
    local line_count = harness.run_lua('return vim.api.nvim_buf_line_count(require("notebashpp.json_tree").panel.buffer)')
    expect_equal(100000, line_count, 'every level open down to the caret')
    local header = panel_header()
    expect_equal(true, #header < 60 and header:sub(-6) == '[0][0]', 'the end of a 300 kb path: ' .. header)
    harness.run_lua('vim.api.nvim_buf_set_lines(0, 0, -1, false, { string.rep("{\\"a\\":", 100000) })')
    harness.wait_until_idle(450)
    wait_for_tree()
    expect_equal('Line 1, column 499996: this "{" is never closed.', panel_message(), 'unclosed 100,000 levels')
    close_json_tree()
    -- json syntax highlighting chokes on a 10 mb line by itself (e363, panel
    -- or not). the panel is what's tested here, so the colours go.
    harness.run_lua('vim.bo.syntax = "OFF"')
    harness.run_lua(
        'vim.api.nvim_buf_set_lines(0, 0, -1, false, { "{\\"big\\": \\"" .. string.rep("x", 10 * 1024 * 1024) .. "\\", \\"escapes\\": \\"" .. string.rep("\\\\u0041", 1000000) .. "\\"}" })'
    )
    harness.set_cursor_position(1, 0)
    seconds = harness.run_lua([[
        local started = vim.uv.hrtime()
        require('notebashpp.json_tree').toggle()
        return (vim.uv.hrtime() - started) / 1e9
    ]])
    wait_for_tree()
    expect_equal(true, seconds < 2, ('the first slice returned in %.2f s'):format(seconds))
    local lines = panel_lines()
    expect_equal('     big: "xxxxxxxxxxxxxxxxxxxxxxxx..."', lines[2], '10 MB string cut')
    expect_equal(true, #lines[3] < 60, 'escapes cut: ' .. lines[3])
end)
test_case('the JSON tree refuses documents that are too large or not JSON', function()
    open_json('people.json', people_lines)
    harness.run_lua('require("notebashpp.user_settings").values.json_tree_megabytes = 0.0001')
    harness.run_lua('require("notebashpp.json_tree").toggle()')
    harness.wait_until_idle(60)
    local too_large = panel_message()
    harness.run_lua('require("notebashpp.user_settings").values.json_tree_megabytes = 20')
    expect_equal(true, vim.startswith(too_large, 'This document is 0.0 MB, too large for the JSON tree.'), too_large)
    harness.run_lua('vim.cmd("enew")')
    harness.wait_until_idle(60)
    expect_equal(true, vim.startswith(panel_message(), 'This document is not JSON.'), 'follows the document: not JSON')
    harness.run_lua('vim.cmd("buffer people.json")')
    harness.wait_until_idle(60)
    expect_equal(' - people.json {3}', panel_lines()[1], 'back to the JSON document')
end)
test_case('the JSON tree panel keeps its window and closes with Esc', function()
    open_json('people.json', people_lines)
    harness.run_lua('require("notebashpp.json_tree").toggle()')
    harness.wait_until_idle(60)
    -- a document switched into the panel goes back to the document window.
    harness.run_lua([[
        local panel = require('notebashpp.json_tree').panel
        vim.api.nvim_set_current_win(panel.window)
        vim.cmd('enew')
    ]])
    harness.wait_until_idle(80)
    expect_equal(
        true,
        harness.run_lua([[
        local panel = require('notebashpp.json_tree').panel
        return vim.api.nvim_win_get_buf(panel.window) == panel.buffer and vim.api.nvim_get_current_win() == panel.source_window
    ]]),
        'panel buffer back in its window'
    )
    harness.run_lua('vim.cmd("buffer people.json")')
    select_panel_line('+ users')
    harness.press_keys('<Esc>', 60)
    expect_equal(false, panel_is_open(), 'Esc closes it')
    expect_equal(true, harness.run_lua('return vim.bo.buftype == ""'), 'back in the document')
    harness.run_lua('require("notebashpp.json_tree").toggle()')
    select_panel_line('+ users')
    harness.press_keys('<C-w>', 60)
    expect_equal(false, panel_is_open(), 'Ctrl+W closes the panel, not a document')
    expect_equal('people.json', harness.run_lua('return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")'), 'document still open')
    local menu_labels = harness.run_lua([[
        local labels = {}
        for _, top in ipairs(require('notebashpp.menu_bar').MENUS) do
            if top.name == 'plugins' then
                for _, item in ipairs(top.items) do
                    if item.label == '&JSON' then
                        for _, sub_item in ipairs(item.sub) do labels[#labels + 1] = sub_item.label or '-' end
                    end
                end
            end
        end
        return labels
    ]])
    expect_equal({ '&Format JSON', '&Minify JSON', '&Check JSON', '-', 'Show JSON &Tree', 'Copy JSON &Path' }, menu_labels, 'JSON menu')
end)
test_case('the JSON tree has its colours in both themes', function()
    local light = harness.run_lua('return vim.api.nvim_get_hl(0, { name = "NotebashJsonTree" }).bg')
    harness.run_lua('require("notebashpp.appearance").set_dark_mode(true)')
    local dark = harness.run_lua('return vim.api.nvim_get_hl(0, { name = "NotebashJsonTree" }).bg')
    harness.run_lua('require("notebashpp.appearance").set_dark_mode(false)')
    expect_equal({ 0xF3F3F3, 0x252526 }, { light, dark })
    clean_up_json()
end)

-- these two run last on purpose: they read everything the earlier tests did.
-- an obituary, except i still have to fix the deceased.
test_case('no deprecated Neovim API was used', function()
    expect_equal({}, harness.run_lua('return _G.deprecated_api_calls'))
end)
test_case('no errors were raised', function()
    local messages = harness.run_lua('return vim.fn.execute("messages")')
    local error_lines = {}
    for message_line in messages:gmatch('[^\n]+') do
        if message_line:match('^E%d+') or message_line:match('Error') or message_line:match('stack traceback') then
            error_lines[#error_lines + 1] = message_line
        end
    end
    expect_equal({}, error_lines)
end)

harness.stop_editor()
local all_passed = harness.print_summary()
os.exit(all_passed and 0 or 1)
