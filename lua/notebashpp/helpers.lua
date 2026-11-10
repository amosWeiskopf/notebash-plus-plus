-- small helpers shared by every module. basically i buried the crap here so
-- every module doesn't need its own private disaster.
--
-- positions are {line, col}: line 1-based, col a 0-based byte offset, same as
-- nvim_win_get_cursor(). ranges are end-exclusive, like a windows caret
-- between two characters. even the cursor won't commit. i understand.

local helpers = {}
local api = vim.api

function helpers.replace_termcodes(keys)
    return api.nvim_replace_termcodes(keys, true, false, true)
end

-- queue keys after the current mapping finishes, without remapping them. i
-- want the keys i asked for. apparently this is a fucking feature request.
function helpers.feed_keys(keys)
    api.nvim_feedkeys(helpers.replace_termcodes(keys), 'n', false)
end

-- close the current undo step so the next change undoes on its own. setting
-- undolevels to itself does this. i spent actual life learning that, and
-- there is absolutely no undo for the time.
function helpers.start_new_undo_step()
    vim.o.undolevels = vim.o.undolevels
end

-- selection mode letters: visual & select. \22 is ctrl+v, \19 is ctrl+s,
-- their block variants. even selecting text needs a damn secret handshake.
local selection_modes = { v = true, V = true, ['\22'] = true, s = true, S = true, ['\19'] = true }
local block_selection_modes = { ['\22'] = true, ['\19'] = true }

function helpers.current_mode()
    return vim.fn.mode()
end

function helpers.is_selecting(mode)
    return selection_modes[mode or vim.fn.mode()] or false
end

function helpers.is_editable_buffer(buffer)
    buffer = buffer or 0
    local buffer_type = vim.bo[buffer].buftype
    return (buffer_type == '' or buffer_type == 'acwrite') and vim.bo[buffer].modifiable
end

function helpers.get_caret()
    return api.nvim_win_get_cursor(0)
end

function helpers.get_line_text(line_number, buffer)
    return api.nvim_buf_get_lines(buffer or 0, line_number - 1, line_number, false)[1] or ''
end

function helpers.get_lines_text(first_line, last_line, buffer)
    return api.nvim_buf_get_lines(buffer or 0, first_line - 1, last_line, false)
end

function helpers.count_lines(buffer)
    return api.nvim_buf_line_count(buffer or 0)
end

function helpers.position_is_before(first_position, second_position)
    return first_position[1] < second_position[1] or (first_position[1] == second_position[1] and first_position[2] < second_position[2])
end

-- stream selection as {start_line, start_col, end_line, end_col}, or nil when
-- nothing is selected. block (column) selections live separately in
-- notebashpp.column_mode. i gave the misery its own room.
function helpers.get_selection()
    local mode = vim.fn.mode()
    if not selection_modes[mode] or block_selection_modes[mode] then
        return nil
    end
    local anchor_mark, caret_mark = vim.fn.getpos('v'), vim.fn.getpos('.')
    local start_position, end_position = { anchor_mark[2], anchor_mark[3] - 1 }, { caret_mark[2], caret_mark[3] - 1 }
    if helpers.position_is_before(end_position, start_position) then
        start_position, end_position = end_position, start_position
    end
    if mode == 'V' or mode == 'S' then
        local last_line = helpers.count_lines()
        if end_position[1] < last_line then
            return { start_line = start_position[1], start_col = 0, end_line = end_position[1] + 1, end_col = 0, linewise = true }
        end
        return { start_line = start_position[1], start_col = 0, end_line = end_position[1], end_col = #helpers.get_line_text(end_position[1]), linewise = true }
    end
    end_position[2] = math.min(end_position[2], #helpers.get_line_text(end_position[1]))
    start_position[2] = math.min(start_position[2], #helpers.get_line_text(start_position[1]))
    if start_position[1] == end_position[1] and start_position[2] == end_position[2] then
        return nil
    end
    return { start_line = start_position[1], start_col = start_position[2], end_line = end_position[1], end_col = end_position[2] }
end

function helpers.get_text_in_range(range, buffer)
    return api.nvim_buf_get_text(buffer or 0, range.start_line - 1, range.start_col, range.end_line - 1, range.end_col, {})
end

function helpers.replace_text_in_range(range, lines, buffer)
    api.nvim_buf_set_text(buffer or 0, range.start_line - 1, range.start_col, range.end_line - 1, range.end_col, lines)
end

-- position after inserting `lines` at {line_number, column}. one line moves
-- along; several move down to the end of the last. progress, allegedly. i
-- mostly just end up further down.
function helpers.position_after_inserted_text(line_number, column, lines)
    if #lines == 1 then
        return { line_number, column + #lines[1] }
    end
    return { line_number + #lines - 1, #lines[#lines] }
end

-- lines touched by the selection, or just the caret line. per scintilla,
-- ending at column 0 of a later line excludes that line. showing up counts
-- for absolutely nothing. finally, software agrees with my bank.
function helpers.selected_line_range()
    local selection = helpers.get_selection()
    if not selection then
        local caret_line = helpers.get_caret()[1]
        return caret_line, caret_line, nil
    end
    local last_line = selection.end_line
    if selection.end_col == 0 and last_line > selection.start_line then
        last_line = last_line - 1
    end
    return selection.start_line, last_line, selection
end

-- keys to select from `anchor` to `caret` in select mode, so typing replaces
-- the selection like notepad++. escape the current mode first, whatever the
-- hell neovim thinks we're doing. i just wanted to write something.
function helpers.keys_to_select_range(anchor, caret)
    return ('<C-\\><C-n><Cmd>call cursor(%d,%d)<CR>v<Cmd>call cursor(%d,%d)<CR><C-g>'):format(anchor[1], anchor[2] + 1, caret[1], caret[2] + 1)
end

function helpers.select_range(anchor, caret)
    if anchor[1] == caret[1] and anchor[2] == caret[2] then
        return helpers.move_caret_to(caret)
    end
    helpers.feed_keys(helpers.keys_to_select_range(anchor, caret))
end

-- move the caret to `position`, drop any selection and keep typing there.
-- clamp the position into the document first. asking for line 9000 in a 12
-- line file is basically my retirement plan: nothing backing it.
function helpers.move_caret_to(position)
    local line_number = math.max(1, math.min(position[1], helpers.count_lines()))
    local column = math.max(0, math.min(position[2], #helpers.get_line_text(line_number)))
    if helpers.is_selecting() or vim.fn.mode() == 'n' then
        local keys = ('<C-\\><C-n><Cmd>call cursor(%d,%d)<CR>'):format(line_number, column + 1)
        if helpers.is_editable_buffer() then
            keys = keys .. 'i'
        end
        helpers.feed_keys(keys)
    else
        helpers.start_new_undo_step()
        api.nvim_win_set_cursor(0, { line_number, column })
    end
end

-- drop any selection, keep typing at the caret. let go, for once. please.
function helpers.collapse_selection()
    if helpers.is_selecting() then
        helpers.move_caret_to(helpers.get_caret())
    end
end

function helpers.notify(message, level)
    vim.notify(message, level or vim.log.levels.INFO)
end

function helpers.warn(message)
    vim.notify(message, vim.log.levels.WARN)
end

-- word under the caret, or ''. scintilla word characters: letters, digits,
-- underscore & any byte from 128 up, so a hebrew word counts as a word. the
-- computer accepts this. i'd love to know why the rest costs my sanity.
function helpers.word_at_caret()
    local caret = helpers.get_caret()
    local line_text = helpers.get_line_text(caret[1])
    local caret_index = caret[2] + 1
    local function is_word_character(character)
        return character:match('[%w_]') or character:byte() >= 128
    end
    local word_start, word_end = caret_index, caret_index - 1
    while word_start > 1 and is_word_character(line_text:sub(word_start - 1, word_start - 1)) do
        word_start = word_start - 1
    end
    while word_end < #line_text and is_word_character(line_text:sub(word_end + 1, word_end + 1)) do
        word_end = word_end + 1
    end
    if word_end < word_start then
        return '', nil
    end
    return line_text:sub(word_start, word_end), { start_line = caret[1], start_col = word_start - 1, end_line = caret[1], end_col = word_end }
end

-- selected text joined with "\n", or the word at the caret if none.
function helpers.selected_text_or_word_at_caret()
    local selection = helpers.get_selection()
    if selection then
        return table.concat(helpers.get_text_in_range(selection), '\n'), selection
    end
    return helpers.word_at_caret()
end

-- run `action` as one undo step. display any error instead of throwing it. i
-- want failure contained for once. apparently that's possible in lua (my
-- mistake was expecting it elsewhere).
function helpers.run_as_one_undo_step(action, ...)
    helpers.run_command_as_one_undo_step(nil, action, ...)
end

-- the same, with the command's name before any error. the error goes to the
-- message log with its stack trace, and shows as a notification. basically my
-- failures have better documentation than my life.
function helpers.run_command_as_one_undo_step(command_name, action, ...)
    helpers.start_new_undo_step()
    require('notebashpp.messages').call(command_name, action, ...)
    helpers.start_new_undo_step()
end

function helpers.is_running_in_wsl()
    return vim.fn.has('wsl') == 1
end

-- 'wsl', 'windows', 'mac' or 'linux'. every other unix counts as linux. close
-- enough. the same standard that got me this far, unfortunately.
function helpers.platform()
    if vim.fn.has('wsl') == 1 then
        return 'wsl'
    elseif vim.fn.has('win32') == 1 then
        return 'windows'
    elseif vim.fn.has('mac') == 1 then
        return 'mac'
    end
    return 'linux'
end

-- start a program without waiting; return false if it isn't installed. under
-- wsl, start in / unless working_directory is given. / survives whatever
-- directory i deleted (already more dependable than my plans). look up the
-- program's full path first: on windows a bare name can match notepad.exe in
-- the current folder, which might be a stranger's repo. i want to launch an
-- editor. apparently this requires deciding whose executable gets to finish
-- fucking up my life.
function helpers.start_detached(command, working_directory, environment)
    local program_path = vim.fn.exepath(command[1])
    if program_path == '' then
        return false
    end
    command = vim.list_extend({ program_path }, command, 2)
    local started = pcall(
        vim.system,
        command,
        { detach = true, env = helpers.windows_child_environment(environment), cwd = working_directory or (vim.fn.has('wsl') == 1 and '/' or nil) }
    )
    return started
end

-- environment for a program that may be a windows one: `environment` plus
-- nodefaultcurrentdirectoryinexepath, so cmd.exe running `start cmd.exe`
-- doesn't pick up cmd.exe from the current folder either. absolutely no need
-- to give a stranger's executable the access i've wasted my life on. under
-- wsl, add the names to wslenv too (the list of variables wsl hands over to
-- windows). apparently even this shit needs a formal introduction.
function helpers.windows_child_environment(environment)
    environment = vim.tbl_extend('force', { NoDefaultCurrentDirectoryInExePath = '1' }, environment or {})
    if vim.fn.has('wsl') == 1 then
        local shared_names = vim.tbl_filter(function(name)
            return name ~= ''
        end, vim.split(vim.env.WSLENV or '', ':'))
        environment.WSLENV = table.concat(vim.list_extend(shared_names, vim.tbl_keys(environment)), ':')
    end
    return environment
end

-- convert a wsl path for windows programs. outside wsl, or if wslpath fails,
-- return it unchanged. failure gets to leave exactly as it came. lucky.
function helpers.to_windows_path(path)
    if vim.fn.has('wsl') == 0 then
        return path
    end
    local converted_path = vim.fn.system({ 'wslpath', '-w', path })
    if vim.v.shell_error ~= 0 then
        return path
    end
    return vim.trim(converted_path)
end

-- accept windows paths (c:\x, \\wsl.localhost\ubuntu\x) & linux paths, with
-- or without the quotes from windows copy as path. i now negotiate between
-- operating systems to open a file. my potential was apparently much smaller
-- than advertised.
--
-- if a name exists exactly as given, use it as is, spaces and all. expand
-- only a leading ~. never use vim.fn.expand(): it runs `backticks` as shell
-- commands, so opening report`rm -rf ~`.txt would delete your home folder.
-- basically a file gets to erase everything i've worked on, and i get to
-- spend my remaining years explaining that i clicked it. i'd still like you
-- to keep your files. someone should get something out of this.
function helpers.from_windows_path(path)
    if path ~= '' and vim.uv.fs_stat(path) then
        return path
    end
    path = vim.trim(path):gsub('^"(.*)"$', '%1')
    if vim.fn.has('wsl') == 1 and (path:match('^%a:[\\/]') or path:match('^\\\\')) then
        local converted_path = vim.fn.system({ 'wslpath', '-u', path })
        if vim.v.shell_error == 0 then
            return vim.trim(converted_path)
        end
    end
    if path == '~' or path:match('^~[/\\]') then
        path = vim.uv.os_homedir() .. path:sub(2)
    end
    return path
end

-- ask on the command line with vim.fn.input, take the answer, then clear the
-- question. otherwise "go to line: 19" stays after you've gone there. even a
-- fucking prompt won't accept that i did what it asked.
function helpers.ask(prompt, default_answer, completion)
    local answer
    if completion then
        answer = vim.fn.input(prompt, default_answer or '', completion)
    else
        answer = vim.fn.input(prompt, default_answer or '')
    end
    vim.cmd('echo ""')
    return answer
end

-- a document buffer: plain text, or a web page or ssh file
-- (remote_documents.lua), which uses buftype acwrite so saving goes through
-- its own code. same rights, different landlord.
function helpers.is_document_buffer(buffer)
    local buffer_type = vim.bo[buffer].buftype
    return buffer_type == '' or (buffer_type == 'acwrite' and vim.b[buffer].notebashpp_remote == true)
end

-- write private state (sessions, preferences, macros) whole or not at all:
-- create the temporary file as 0600 before a single byte goes in, write it,
-- then rename it over the old one. the folder becomes 0700. a crash mid-write
-- leaves the old file whole. the process id keeps two instances out of each
-- other's way. my secrets get better handling than my feelings ever did.
---@param lines string[]
---@param path string
---@param flags string? passed to writefile ('b' for no final line end)
function helpers.write_private_file(lines, path, flags)
    local folder = vim.fs.dirname(path)
    vim.fn.mkdir(folder, 'p')
    vim.uv.fs_chmod(folder, tonumber('700', 8))
    local temporary_path = ('%s.%d.writing'):format(path, vim.fn.getpid())
    local file_descriptor = vim.uv.fs_open(temporary_path, 'w', tonumber('600', 8))
    if not file_descriptor then
        error('Could not write ' .. temporary_path)
    end
    vim.uv.fs_close(file_descriptor)
    if vim.fn.writefile(lines, temporary_path, flags or '') ~= 0 then
        vim.fn.delete(temporary_path)
        error('Could not write ' .. temporary_path)
    end
    vim.uv.fs_chmod(temporary_path, tonumber('600', 8))
    local renamed, rename_error = vim.uv.fs_rename(temporary_path, path)
    if not renamed then
        vim.fn.delete(temporary_path)
        error(rename_error)
    end
end

return helpers
