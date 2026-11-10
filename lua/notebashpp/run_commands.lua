-- the run menu: f5 run, plus three commands from a notepad++ shortcuts.xml:
-- alt+f1 get php help, alt+f3 wikipedia search, alt+f6 open the selected file
-- path in a new instance. somebody needed php help often enough to assign a
-- key. basically a cry for help with excellent keyboard access.

local run_commands = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- remember the last command typed into the run dialog & offer it next time. i
-- want fewer keystrokes between me and the same damn mistake.
run_commands.last_command = ''

-- notepad++'s current word: use the selection if there is one, otherwise the
-- word under the caret. even indecision gets a fallback. lucky bastard.
local function selection_or_word_at_caret()
    local selected_text = helpers.selected_text_or_word_at_caret()
    return selected_text
end

-- expand notepad++ $(variables) in a command line: the current file's path,
-- folder, name and extension, the current word, line and column (1-based, as
-- notepad++ counts), and the line's text. npp_directory points at notebash++
-- itself. $(sys) and unknown variables become empty strings. i want this much
-- forgiveness from my bank. unknown debt? empty string. absolutely beautiful.
local function notepadpp_variable_values()
    local current_path = api.nvim_buf_get_name(0)
    return {
        FULL_CURRENT_PATH = current_path,
        CURRENT_DIRECTORY = current_path ~= '' and vim.fn.fnamemodify(current_path, ':h') or vim.fn.getcwd(),
        FILE_NAME = vim.fn.fnamemodify(current_path, ':t'),
        NAME_PART = vim.fn.fnamemodify(current_path, ':t:r'),
        EXT_PART = vim.fn.fnamemodify(current_path, ':e'),
        CURRENT_WORD = selection_or_word_at_caret(),
        CURRENT_LINE = tostring(helpers.get_caret()[1]),
        CURRENT_COLUMN = tostring(helpers.get_caret()[2] + 1),
        CURRENT_LINESTR = helpers.get_line_text(helpers.get_caret()[1]),
        NPP_DIRECTORY = require('notebashpp').root,
        NPP_FULL_FILE_PATH = require('notebashpp').root .. '/bin/notebash++',
        SYS = '',
    }
end

function run_commands.expand_notepadpp_variables(command_line)
    local variable_values = notepadpp_variable_values()
    return (command_line:gsub('%$%(([%w_]+)%)', function(variable_name)
        return variable_values[variable_name] or ''
    end))
end

-- the shell version of the above. paste a file name or the line under the
-- caret into a shell command and it runs whatever that text says. a file
-- called $(rm -rf ~).txt can basically delete my home. cheaper than rent. so
-- every value goes in an environment variable named notebashpp_<name>. the
-- command only references it, quoted for wherever $(name) sits: bare, inside
-- "double" or inside 'single' quotes. the shell expands a variable once and
-- never runs its contents (a restraint i wish i'd learned). cmd.exe has no
-- safe way to quote a double quote, so on windows we drop those from the
-- values. i trust my files about as much as their authors. i wrote most of
-- them. absolutely damning evidence.
function run_commands.shell_command_with_variables(command_line)
    local variable_values = notepadpp_variable_values()
    local environment = {}
    local on_windows = vim.fn.has('win32') == 1
    local pieces, quote, position = {}, nil, 1
    while position <= #command_line do
        local variable_name = command_line:match('^%$%(([%w_]+)%)', position)
        local character = command_line:sub(position, position)
        if variable_name then
            local environment_name = 'NOTEBASHPP_' .. variable_name
            local value = variable_values[variable_name] or ''
            environment[environment_name] = on_windows and value:gsub('"', '') or value
            local reference = on_windows and ('%' .. environment_name .. '%') or ('${' .. environment_name .. '}')
            if quote == '"' then
                pieces[#pieces + 1] = reference
            elseif quote == "'" then
                pieces[#pieces + 1] = '\'"' .. reference .. '"\''
            else
                pieces[#pieces + 1] = '"' .. reference .. '"'
            end
            position = position + #variable_name + 3
        else
            -- copy escaped characters with their escape; quote state stays
            -- unchanged: \" in sh, ^" outside quotes in cmd.exe. even this
            -- shit has boundaries.
            local escape_character = on_windows and '^' or '\\'
            if character == escape_character and quote ~= "'" and not (on_windows and quote == '"') then
                pieces[#pieces + 1] = command_line:sub(position, position + 1)
                position = position + 2
            else
                if quote == nil and (character == '"' or (character == "'" and not on_windows)) then
                    quote = character
                elseif character == quote then
                    quote = nil
                end
                pieces[#pieces + 1] = character
                position = position + 1
            end
        end
    end
    return table.concat(pieces), environment
end

-- percent-encode everything except letters, digits and - . _ ~. "c++ regrets"
-- survives the url. i've invested years in those regrets.
local function url_encode(text)
    return (text:gsub('[^%w%-%._~]', function(character)
        return ('%%%02X'):format(character:byte())
    end))
end

-- open a url in the browser. on wsl, explorer.exe uses the windows default
-- browser. if unavailable, or anywhere else, use neovim's vim.ui.open. two
-- editors & an operating system to outsource my disappointment.
function run_commands.open_url(url)
    if not (helpers.is_running_in_wsl() and helpers.start_detached({ 'explorer.exe', url })) then
        vim.ui.open(url)
    end
end

-- run the dialog's command. anything resembling a url (scheme://...) opens in
-- the browser. url-encode its last piece (after the final ?, = or /) when
-- that piece has no / or ? itself, so a selected word can safely enter a
-- search url. everything else starts as a detached job in the working
-- directory. we never hear from it again. apparently a process can leave this
-- relationship more easily than i can.
function run_commands.run_command_line(command_line, environment)
    command_line = vim.trim(command_line)
    if command_line == '' then
        return
    end
    if command_line:match('^%a[%w+.-]*://') then
        local url_base, last_part = command_line:match('^(.-[?=/])([^?=/]*)$')
        if url_base and last_part ~= '' and not last_part:find('[/?]') then
            command_line = url_base .. url_encode(last_part)
        end
        return run_commands.open_url(command_line)
    end
    vim.fn.jobstart(command_line, { detach = true, cwd = vim.fn.getcwd(), env = environment })
end

-- f5. notepad++'s run dialog reduced to one prompt with shell completion.
-- remember the command before expanding $(variables), so next time you get
-- the unexpanded template back. i keep my potential unexpanded too. less
-- painful than finding out.
function run_commands.run_dialog()
    local typed_command = helpers.ask('Run - The Program to Run: ', run_commands.last_command, 'shellcmd')
    if typed_command == '' then
        return
    end
    run_commands.last_command = typed_command
    if vim.trim(typed_command):match('^%a[%w+.-]*://') then
        run_commands.run_command_line(run_commands.expand_notepadpp_variables(typed_command))
    else
        run_commands.run_command_line(run_commands.shell_command_with_variables(typed_command))
    end
end

-- alt+f1. php manual page for the current word. still php. sorry.
function run_commands.php_help()
    run_commands.run_command_line(run_commands.expand_notepadpp_variables('https://www.php.net/$(CURRENT_WORD)'))
end

-- alt+f3. search wikipedia for the current word. all that human effort, and
-- i'm checking whether someone more successful than me is dead yet.
function run_commands.wikipedia()
    run_commands.run_command_line(run_commands.expand_notepadpp_variables('https://en.wikipedia.org/wiki/Special:Search?search=$(CURRENT_WORD)'))
end

-- alt+f6. open the selected path in a second notebash++ window, without the
-- session. accept windows paths; if the path doesn't exist as typed, try it
-- relative to the current file's folder. on wsl, launch a new neovide through
-- the launcher. elsewhere, use plain neovide with notebashpp_no_session
-- switching the session off. in a terminal inside tmux, use a new tmux
-- window. if a second instance isn't possible, open the file here. i wanted a
-- fresh start and got the same window. basically my life, except this time
-- there's a documented reason.
function run_commands.open_in_new_instance()
    local selected_path_text = vim.trim(selection_or_word_at_caret())
    if selected_path_text == '' then
        return
    end
    local target_path = helpers.from_windows_path(selected_path_text)
    if vim.fn.filereadable(target_path) == 0 and vim.fn.isdirectory(target_path) == 0 then
        local current_directory = vim.fn.fnamemodify(api.nvim_buf_get_name(0), ':h')
        local relative_path = current_directory .. '/' .. selected_path_text
        if vim.fn.filereadable(relative_path) == 1 then
            target_path = relative_path
        end
    end
    local launcher_path = require('notebashpp').root .. '/bin/notebash++'
    if vim.g.neovide and helpers.is_running_in_wsl() then
        vim.system({ launcher_path, '-gui', '-nosession', '-multiInst', '--', target_path }, { detach = true })
    elseif vim.g.neovide and vim.fn.executable('neovide') == 1 then
        vim.system({ 'neovide', '--', '--', target_path }, {
            detach = true,
            env = { NVIM_APPNAME = vim.env.NVIM_APPNAME, NOTEBASHPP_NO_SESSION = '1' },
        })
    elseif vim.env.TMUX then
        vim.system({ 'tmux', 'new-window', launcher_path, '-nosession', '-multiInst', '--', target_path })
    else
        require('notebashpp.file_commands').open_path(target_path)
    end
end

return run_commands
