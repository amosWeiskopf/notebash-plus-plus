-- the file menu: new, open, reload, save, save as, save all, close, close
-- all, restore recent closed file, print, exit. basically a document's whole
-- life. i gave it more choices than i gave myself. it still ends in a damn
-- box.

local file_commands = {}
local api = vim.api
local helpers = require('notebashpp.helpers')
local document_tabs = require('notebashpp.document_tabs')

-- closed document paths, newest last, for ctrl+shift+t. live code reload
-- keeps this list. i can replace the code; apparently the regrets are tenure.
file_commands.closed = {}

local function display_name(buffer)
    return document_tabs.full_name(buffer)
end

-- open & save prompts start in the document's folder, or the working
-- directory if unnamed. even my empty documents are stuck at work.
local function starting_directory(buffer)
    local buffer_path = api.nvim_buf_get_name(buffer or 0)
    if buffer_path ~= '' then
        return vim.fn.fnamemodify(buffer_path, ':p:h') .. '/'
    end
    return vim.fn.getcwd() .. '/'
end

-- ctrl+n. a fresh "new n" with windows line endings, like notepad++. i want a
-- clean start. absolutely, here is another file to die unfinished.
function file_commands.new()
    local new_buffer = api.nvim_create_buf(true, false)
    document_tabs.name_new(new_buffer)
    vim.bo[new_buffer].fileformat = 'dos'
    api.nvim_set_current_buf(new_buffer)
end

-- open `path`, including windows paths. an untouched "new 1" steps aside,
-- like in notepad++. no severance for the bastard. if the path is a folder,
-- show a picker of its entries. unemployment with file completion, basically.
function file_commands.open_path(path)
    path = require('notebashpp.remote_documents').normalize(helpers.from_windows_path(path))
    if path == '' then
        return
    end
    local buffer_before = api.nvim_get_current_buf()
    local was_pristine = document_tabs.is_pristine(buffer_before)
    if vim.fn.isdirectory(path) == 1 then
        local directory_entries = vim.fn.readdir(path)
        table.sort(directory_entries)
        vim.ui.select(directory_entries, { prompt = 'Open from ' .. path }, function(chosen_entry)
            if chosen_entry then
                file_commands.open_path(vim.fs.joinpath(path, chosen_entry))
            end
        end)
        return
    end
    local opened, open_error = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    if not opened then
        helpers.warn(open_error)
        return
    end
    local buffer_after = api.nvim_get_current_buf()
    if was_pristine and buffer_after ~= buffer_before and api.nvim_buf_is_valid(buffer_before) then
        pcall(api.nvim_buf_delete, buffer_before, { force = true })
    end
end

-- a second `notebash++ file` hands its file over here. open it after the
-- launcher's call has returned, so a question (html or markdown?) can wait
-- for an answer, then go to the line and column if given. i also prefer to
-- get bad news after the meeting.
---@param path string
---@param line_text string? digits or ''
---@param column_text string? digits or ''
function file_commands.open_from_launcher(path, line_text, column_text)
    vim.schedule(function()
        file_commands.open_path(path)
        local line_number = tonumber(line_text or '')
        if line_number then
            pcall(vim.fn.cursor, line_number, tonumber(column_text or '') or 1)
        end
    end)
    return 0
end

-- ctrl+o. plain prompt, file completion, starting in the current document's
-- folder. i couldn't afford hope, so you get a line to type in.
function file_commands.open()
    local typed_path = helpers.ask('Open: ', starting_directory(), 'file')
    if typed_path ~= '' then
        file_commands.open_path(typed_path)
    end
end

-- reload from disk. unsaved changes get a question, defaulting to no.
-- throwing away work takes one deliberate keypress (my career took years).
-- restore the view afterwards, including caret & scroll. same shit, same
-- seat.
function file_commands.reload()
    local buffer = api.nvim_get_current_buf()
    if api.nvim_buf_get_name(buffer) == '' then
        return
    end
    if vim.bo[buffer].modified then
        local choice = vim.fn.confirm('Are you sure you want to reload the current file and lose the changes made in Notebash++?', '&Yes\n&No', 2, 'Question')
        if choice ~= 1 then
            return
        end
    end
    local saved_view = vim.fn.winsaveview()
    vim.cmd('silent edit!')
    vim.fn.winrestview(saved_view)
end

-- save one buffer; nil or 0 means current. unnamed documents use save as.
-- returns true once saved to disk. i want to call that safety, but i've owned
-- computers. read-only files get the notepad++ question; yes forces the
-- write. apparently consent is what separates saving from vandalism.
function file_commands.save(buffer)
    buffer = (buffer == nil or buffer == 0) and api.nvim_get_current_buf() or buffer
    if api.nvim_buf_get_name(buffer) == '' then
        return file_commands.save_as(buffer)
    end
    local remote_documents = require('notebashpp.remote_documents')
    if remote_documents.kind(api.nvim_buf_get_name(buffer)) then
        return remote_documents.save(buffer)
    end
    -- snapshot-restored document: if its disk file changed after the edits,
    -- ask before older edits overwrite the newer file. i want consent before
    -- my past fucks up somebody's present.
    local snapshot_disk_time = vim.b[buffer].notebashpp_snapshot_disk_time
    if snapshot_disk_time and vim.fn.getftime(api.nvim_buf_get_name(buffer)) > snapshot_disk_time then
        if vim.fn.confirm(display_name(buffer) .. ' changed on disk after your unsaved edits. Overwrite it?', '&Yes\n&No', 2, 'Warning') ~= 1 then
            return false
        end
    end
    vim.b[buffer].notebashpp_snapshot_disk_time = nil
    local renamed_file_time = vim.b[buffer].notebashpp_renamed
    if renamed_file_time then
        local path = api.nvim_buf_get_name(buffer)
        local question
        if vim.fn.getftime(path) ~= renamed_file_time and vim.fn.getftime(path) ~= -1 then
            question = display_name(buffer) .. ' changed on disk after the rename. Overwrite it?'
        elseif vim.fn.filereadable(path) == 1 and vim.fn.filewritable(path) == 0 then
            question = display_name(buffer) .. ' is read-only. Save it anyway?'
        end
        if question and vim.fn.confirm(question, '&Yes\n&No', 2, 'Warning') ~= 1 then
            return false
        end
    end
    local written, write_error = pcall(api.nvim_buf_call, buffer, function()
        if renamed_file_time then
            -- neovim refuses plain :write after a buffer rename (e13, file
            -- exists). this is the renamed file itself, checked just above.
            -- apparently i must prove it exists before asking this bastard to
            -- write it.
            vim.cmd('silent write!')
            vim.b[buffer].notebashpp_renamed = nil
        else
            vim.cmd('silent write')
        end
    end)
    if not written then
        if tostring(write_error):match('E45') or tostring(write_error):match('readonly') then
            local choice = vim.fn.confirm(display_name(buffer) .. ' is read-only. Save it anyway?', '&Yes\n&No', 2, 'Warning')
            if choice == 1 then
                written, write_error = pcall(api.nvim_buf_call, buffer, function()
                    vim.cmd('silent write!')
                end)
            end
        end
        if not written then
            helpers.warn('Save failed: ' .. tostring(write_error))
            return false
        end
    end
    vim.cmd('redrawstatus!')
    return true
end

-- ask where to save; windows paths accepted. unnamed documents get
-- "<folder>/new 1.txt". replacing any existing file except the document's own
-- needs confirmation, including the offered "new 1.txt". somebody else's crap
-- from last week still belongs to them (property survives hope, apparently).
-- returns nil when cancelled.
local function ask_for_save_path(prompt, buffer)
    local default_path = require('notebashpp.remote_documents').save_as_default(buffer) or api.nvim_buf_get_name(buffer)
    if default_path == '' then
        default_path = starting_directory(buffer) .. document_tabs.name(buffer) .. '.txt'
    end
    local chosen_path = helpers.ask(prompt, default_path, 'file')
    if chosen_path == '' then
        return nil
    end
    chosen_path = helpers.from_windows_path(chosen_path)
    -- a renamed "new n" document never read or wrote that file. it doesn't
    -- own it. i named my debts "potential" once, same shit.
    local own_path = vim.b[buffer].notebashpp_new == nil and api.nvim_buf_get_name(buffer) or ''
    if vim.fn.filereadable(chosen_path) == 1 and (own_path == '' or vim.fn.fnamemodify(chosen_path, ':p') ~= vim.fn.fnamemodify(own_path, ':p')) then
        local choice = vim.fn.confirm(chosen_path .. ' already exists.\nDo you want to replace it?', '&Yes\n&No', 2, 'Warning')
        if choice ~= 1 then
            return nil
        end
    end
    return chosen_path
end

-- ctrl+alt+s. give the buffer its new name, remove "new n" status & guess
-- filetype again from the extension. a cheap identity change. still my crap.
function file_commands.save_as(buffer)
    buffer = (buffer == nil or buffer == 0) and api.nvim_get_current_buf() or buffer
    local target_path = ask_for_save_path('Save As: ', buffer)
    if not target_path then
        return false
    end
    -- a web page or ssh file saved as a local file becomes a normal document.
    local was_remote_buftype = vim.bo[buffer].buftype == 'acwrite' and require('notebashpp.remote_documents').kind(api.nvim_buf_get_name(buffer)) ~= nil
    if was_remote_buftype then
        vim.bo[buffer].buftype = ''
    end
    local saved, save_error = pcall(api.nvim_buf_call, buffer, function()
        -- structured, so a newline in the name can't start a second command.
        -- one bad decision per save is plenty.
        vim.cmd.saveas({ args = { target_path }, bang = true, mods = { silent = true }, magic = { file = false } })
    end)
    if not saved then
        if was_remote_buftype then
            vim.bo[buffer].buftype = 'acwrite'
        end
        helpers.warn('Save failed: ' .. tostring(save_error))
        return false
    end
    vim.b[buffer].notebashpp_new = nil
    vim.b[buffer].notebashpp_save_as_name = nil
    if was_remote_buftype then
        vim.b[buffer].notebashpp_remote = nil
        vim.bo[buffer].swapfile = vim.go.swapfile
    end
    vim.cmd('filetype detect')
    vim.cmd('redrawstatus!')
    return true
end

-- write a copy elsewhere; keep editing the original. now my failure has a
-- second address. excellent, i always wanted property.
function file_commands.save_copy_as()
    local buffer = api.nvim_get_current_buf()
    local copy_path = ask_for_save_path('Save a Copy As: ', buffer)
    if copy_path then
        local written, write_error = pcall(vim.api.nvim_command, 'silent write! ' .. vim.fn.fnameescape(copy_path))
        if not written then
            helpers.warn(write_error)
        end
    end
end

-- ctrl+shift+s. notepad++ asks first with saveallconfirm="yes" in config.xml,
-- so we do too. bring unnamed documents forward before save as, so you see
-- what you're naming. i want witnesses when i give another failure a title.
function file_commands.save_all()
    local modified_buffers = {}
    for _, buffer in ipairs(document_tabs.sync()) do
        if vim.bo[buffer].modified then
            modified_buffers[#modified_buffers + 1] = buffer
        end
    end
    if #modified_buffers == 0 then
        return
    end
    local choice = vim.fn.confirm('Are you sure you want to save all modified documents?', '&Yes\n&No', 1, 'Question')
    if choice ~= 1 then
        return
    end
    for _, buffer in ipairs(modified_buffers) do
        if api.nvim_buf_get_name(buffer) == '' then
            api.nvim_set_current_buf(buffer)
        end
        file_commands.save(buffer)
    end
end

-- close one document. changes get a save question (yes, no, cancel); returns
-- false on cancel. closing the last untouched "new 1" does nothing. notepad++
-- always keeps one document open. even this shit needs company. every window
-- showing the buffer moves to the previous tab, or a brand new document if
-- none exists. i built abandonment with replacement housing.
function file_commands.close(buffer, close_options)
    close_options = close_options or {}
    buffer = (buffer == nil or buffer == 0) and api.nvim_get_current_buf() or buffer
    if not api.nvim_buf_is_valid(buffer) then
        return true
    end
    -- ctrl+w in a side panel closes the panel. it was never a document,
    -- it just sat next to one. i know the role.
    if vim.b[buffer].notebashpp_panel == 'json_tree' then
        require('notebashpp.json_tree').close()
        return true
    end
    if vim.bo[buffer].modified and not close_options.force then
        local choice = vim.fn.confirm(('Save file "%s" ?'):format(display_name(buffer)), '&Yes\n&No\n&Cancel', 1, 'Question')
        if choice == 1 then
            if not file_commands.save(buffer) then
                return false
            end
        elseif choice ~= 2 then
            return false
        end
    end
    local tab_order = document_tabs.sync()
    if #tab_order == 1 and tab_order[1] == buffer and document_tabs.is_pristine(buffer) then
        return true
    end
    local buffer_path = api.nvim_buf_get_name(buffer)
    if buffer_path ~= '' then
        table.insert(file_commands.closed, buffer_path)
    end
    local replacement_buffer = document_tabs.previous(buffer)
    if not replacement_buffer then
        replacement_buffer = api.nvim_create_buf(true, false)
        document_tabs.name_new(replacement_buffer)
    end
    for _, window in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_buf(window) == buffer then
            api.nvim_win_set_buf(window, replacement_buffer)
        end
    end
    pcall(api.nvim_buf_delete, buffer, { force = true })
    document_tabs.sync()
    vim.cmd('redrawstatus!')
    return true
end

-- the "close multiple documents" menu. which_documents is 'all', 'others',
-- 'left', 'right' or 'unchanged', by tab position from the current document.
-- bring modified documents forward for their save question. one cancel stops
-- the whole eviction. afterwards restore the current document to the front if
-- it survived. basically more tenant protection than i get.
function file_commands.close_many(which_documents)
    local current_buffer = api.nvim_get_current_buf()
    local tab_order = vim.deepcopy(document_tabs.sync())
    local current_index = 1
    for tab_index, buffer in ipairs(tab_order) do
        if buffer == current_buffer then
            current_index = tab_index
        end
    end
    for tab_index, buffer in ipairs(tab_order) do
        local should_close = which_documents == 'all'
            or (which_documents == 'others' and buffer ~= current_buffer)
            or (which_documents == 'left' and tab_index < current_index)
            or (which_documents == 'right' and tab_index > current_index)
            or (which_documents == 'unchanged' and not vim.bo[buffer].modified)
        if should_close and api.nvim_buf_is_valid(buffer) then
            if api.nvim_get_current_buf() ~= buffer and vim.bo[buffer].modified then
                api.nvim_set_current_buf(buffer)
            end
            if not file_commands.close(buffer) then
                return
            end
        end
    end
    if which_documents ~= 'all' and api.nvim_buf_is_valid(current_buffer) then
        api.nvim_set_current_buf(current_buffer)
    end
end

-- ctrl+shift+t. reopen the most recently closed file still on disk that isn't
-- already open again. skip the missing ones. i can undo closing a text file;
-- the years spent writing this crap remain absolutely gone.
function file_commands.restore_closed()
    while #file_commands.closed > 0 do
        local closed_path = table.remove(file_commands.closed)
        if vim.fn.bufexists(closed_path) == 0 or not vim.bo[vim.fn.bufnr(closed_path)].buflisted then
            if vim.fn.filereadable(closed_path) == 1 then
                file_commands.open_path(closed_path)
                return
            end
        end
    end
end

-- file menu history: neovim first, then notepad++'s config.xml. existing
-- files only, no duplicates, at most `limit` (default 10). a short list of
-- past mistakes. i wish mine fit in 10 entries.
function file_commands.recent(limit)
    limit = limit or 10
    local recent_paths, already_listed = {}, {}
    local function add_path(path)
        if #recent_paths < limit and path ~= '' and not already_listed[path] and vim.fn.filereadable(path) == 1 then
            already_listed[path] = true
            recent_paths[#recent_paths + 1] = path
        end
    end
    for _, path in ipairs(vim.v.oldfiles or {}) do
        add_path(path)
    end
    for _, path in ipairs(require('notebashpp.notepadpp_settings_import').history()) do
        add_path(path)
    end
    return recent_paths
end

-- ctrl+p. neovim cannot print. years of development and i still need another
-- program to put my crap on paper. send text through a temporary file to
-- windows notepad (notepad.exe /p) on windows & wsl, or lp (cups) on linux &
-- macos. use the default printer. let the trees file a complaint.
-- from wsl, notepad gets a file in windows' own temp folder (c:\users\...),
-- since a \\wsl.localhost path is the kind of thing windows notepad was seen
-- crashing on. asking cmd.exe for %temp% gets 3 seconds; after that we give
-- up and use the linux temp folder, like we did before we knew better.
local function windows_side_temporary_file()
    local ok, process = pcall(vim.system, { 'cmd.exe', '/c', 'echo %TEMP%' }, { text = true, cwd = '/' })
    local result = ok and process:wait(3000) or nil
    local windows_temp_folder = result and result.code == 0 and vim.trim(result.stdout or '') or ''
    if windows_temp_folder ~= '' and not windows_temp_folder:find('%', 1, true) then
        local linux_view_of_folder = helpers.from_windows_path(windows_temp_folder)
        if vim.fn.isdirectory(linux_view_of_folder) == 1 then
            -- if the editor died before its 2 minute cleanup (below), delete
            -- leftover copies once they're 10 minutes old. i want my crap to
            -- outlive me less.
            -- vim.fs.dir, not glob(): glob runs `backticks` in the folder name.
            -- even cleaning up after myself turned out to be an attack surface.
            for entry_name, entry_type in vim.fs.dir(linux_view_of_folder) do
                local old_copy = linux_view_of_folder .. '/' .. entry_name
                if entry_type == 'file' and entry_name:match('^notebashpp%-print%-%x+%.txt$') and os.time() - vim.fn.getftime(old_copy) > 600 then
                    vim.fn.delete(old_copy)
                end
            end
            return ('%s/notebashpp-print-%s.txt'):format(
                linux_view_of_folder,
                vim.text.hexencode(assert(vim.uv.random(8), 'no random bytes for the print file name'))
            )
        end
    end
    return vim.fn.tempname() .. '.txt'
end

function file_commands.print()
    local platform = helpers.platform()
    local printer_command
    if platform == 'wsl' or platform == 'windows' then
        printer_command = { 'notepad.exe', '/p' }
    elseif vim.fn.executable('lp') == 1 then
        printer_command = { 'lp' }
    else
        return helpers.warn('Printing needs Windows Notepad or lp (CUPS).')
    end
    local choice = vim.fn.confirm('Print ' .. display_name(0) .. ' on the default printer?', '&Print\n&Cancel', 1)
    if choice ~= 1 then
        return
    end
    local temporary_file = platform == 'wsl' and windows_side_temporary_file() or (vim.fn.tempname() .. '.txt')
    local buffer_lines = api.nvim_buf_get_lines(0, 0, -1, false)
    -- create with 0600 before writing any text. nobody else can read the
    -- copy, not even for a moment. my crap still deserves privacy.
    local file_descriptor = vim.uv.fs_open(temporary_file, 'w', tonumber('600', 8))
    if file_descriptor then
        vim.uv.fs_close(file_descriptor)
    end
    vim.fn.writefile(buffer_lines, temporary_file)
    table.insert(printer_command, helpers.to_windows_path(temporary_file))
    helpers.start_detached(printer_command)
    -- printing leaves a document copy in a temp folder. give notepad or lp 2
    -- minutes to read it, then delete it. even my crap gets a grace period.
    vim.defer_fn(function()
        vim.fn.delete(temporary_file)
    end, 120000)
end

-- alt+f4. with notepad++ session snapshots (issnapshotmode="yes"), keep
-- unsaved work for next time without asking. i built a future for this crap
-- before arranging one for myself. without snapshots, show every modified
-- document & ask; one cancel aborts the whole exit.
function file_commands.exit()
    local session = require('notebashpp.session')
    if session.enabled() then
        session.save()
        vim.cmd('qa!')
        return
    end
    for _, buffer in ipairs(document_tabs.sync()) do
        if vim.bo[buffer].modified then
            api.nvim_set_current_buf(buffer)
            local choice = vim.fn.confirm(('Save file "%s" ?'):format(display_name(buffer)), '&Yes\n&No\n&Cancel', 1, 'Question')
            if choice == 1 then
                if not file_commands.save(buffer) then
                    return
                end
            elseif choice ~= 2 then
                return
            end
        end
    end
    vim.cmd('qa!')
end

-- show the file in the system file manager: explorer selects it on windows &
-- wsl; finder reveals it on macos. linux opens just the folder, since each
-- file manager defines "select" differently. even my shit needs lawyers.
function file_commands.open_containing_folder()
    local path = api.nvim_buf_get_name(0)
    if path == '' then
        return
    end
    local platform = helpers.platform()
    if platform == 'wsl' or platform == 'windows' then
        helpers.start_detached({ 'explorer.exe', '/select,' .. helpers.to_windows_path(path) })
    elseif platform == 'mac' then
        helpers.start_detached({ 'open', '-R', path })
    else
        vim.ui.open(vim.fn.fnamemodify(path, ':h'))
    end
end

-- open a terminal in the document's folder: a new tmux window inside tmux;
-- windows terminal, falling back to cmd.exe, on windows & wsl; the terminal
-- app on macos; $terminal or x-terminal-emulator on linux. warn if none
-- exist. i wanted another shell to hide in, and even that fell through.
function file_commands.open_cmd_here()
    local directory = starting_directory()
    local platform = helpers.platform()
    if vim.env.TMUX then
        vim.system({ 'tmux', 'new-window', '-c', directory })
    elseif platform == 'wsl' or platform == 'windows' then
        -- windows terminal splits arguments at ; into separate commands.
        -- escape the ; in a;calc first. a folder shouldn't get to ruin my day
        -- for free.
        local escaped_directory = helpers.to_windows_path(directory):gsub(';', '\\;')
        if not helpers.start_detached({ 'wt.exe', '-w', '0', 'nt', '-d', escaped_directory }) then
            -- pass the folder as the working directory, never cmd.exe command
            -- text. a folder named a&calc would run calc. i want a shell,
            -- apparently i'm funding a damn escape room.
            helpers.start_detached({ 'cmd.exe', '/c', 'start', 'cmd.exe' }, directory)
        end
    elseif platform == 'mac' then
        helpers.start_detached({ 'open', '-a', 'Terminal', directory })
    else
        local terminal = vim.env.TERMINAL or 'x-terminal-emulator'
        if vim.fn.executable(terminal) == 1 then
            vim.system({ terminal }, { detach = true, cwd = directory })
        else
            helpers.warn('No terminal found: set $TERMINAL.')
        end
    end
end

-- rename. an unsaved document only changes its tab name. a real file gets
-- renamed on disk, then its buffer follows & is written under the new name,
-- so neovim knows it's the same file. i tried changing my name too. the bills
-- found me. apparently identity is whatever still owes money.
function file_commands.rename()
    local buffer = api.nvim_get_current_buf()
    local old_path = api.nvim_buf_get_name(buffer)
    if old_path == '' then
        local new_name = helpers.ask('New name: ', document_tabs.name(buffer))
        if new_name ~= '' then
            api.nvim_buf_set_name(buffer, new_name)
        end
        return
    end
    local new_path = helpers.ask('Rename to: ', old_path, 'file')
    if new_path == '' or new_path == old_path then
        return
    end
    new_path = helpers.from_windows_path(new_path)
    -- don't rename over a file open in another tab. that tab would show a
    -- file that no longer exists, then saving would resurrect it over yours.
    -- even death can't stop this crap overwriting my work.
    local other_buffer = vim.fn.bufnr(vim.fn.fnamemodify(new_path, ':p'))
    if other_buffer ~= -1 and other_buffer ~= buffer and api.nvim_buf_is_loaded(other_buffer) then
        return helpers.warn(new_path .. ' is open in another tab; close it first.')
    end
    -- rename() silently replaces existing files on linux & macos. notepad++
    -- asks, so we ask. consent costs less than recovering my damn work.
    if vim.uv.fs_lstat(new_path) then
        local choice = vim.fn.confirm(new_path .. ' already exists.\nDo you want to replace it?', '&Yes\n&No', 2, 'Warning')
        if choice ~= 1 then
            return
        end
    end
    if vim.fn.rename(old_path, new_path) ~= 0 then
        return helpers.warn('Could not rename ' .. old_path)
    end
    api.nvim_buf_set_name(buffer, new_path)
    -- the disk file is already right; tell neovim its new name. apparently i
    -- also work in software bereavement counselling now. without unsaved
    -- changes, reread it (writes nothing). otherwise keep changes unsaved,
    -- just as before the rename. next ctrl+s must force the write because
    -- neovim says e13, file exists. remember the file's time now & ask before
    -- forcing over a newer one. i'd love this much warning before overwriting
    -- another year of my life.
    if vim.bo[buffer].modified then
        vim.b[buffer].notebashpp_renamed = vim.fn.getftime(new_path)
    else
        local saved_view = vim.fn.winsaveview()
        vim.cmd('silent edit!')
        vim.fn.winrestview(saved_view)
    end
end

-- move to recycle bin or desktop trash when available, so files can come
-- back. windows uses powershell, including from wsl for files under /mnt/c
-- and friends. linux uses gio trash; macos uses its trash command. files on
-- wsl's own disk, or machines without trash, can only be deleted permanently.
-- the question says so & defaults to no either way. i want my files to have
-- another chance. i've basically spent mine teaching a computer how to throw
-- shit away politely.
local function command_to_move_to_trash(path)
    local platform = helpers.platform()
    local windows_path
    if platform == 'windows' then
        windows_path = path
    elseif platform == 'wsl' and path:match('^/mnt/%a/') then
        windows_path = helpers.to_windows_path(path)
    end
    if windows_path then
        -- pass the path to powershell as an environment variable, never
        -- script text. powershell treats ' and curly ’ ‘ as quotes, so a file
        -- named it’s');calc;#.txt could write its own script. my career has
        -- competition from a damn filename.
        return {
            'powershell.exe',
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($env:NOTEBASHPP_TRASH_PATH, "OnlyErrorDialogs", "SendToRecycleBin")',
        }, { NOTEBASHPP_TRASH_PATH = windows_path }
    elseif platform == 'mac' and vim.fn.executable('/usr/bin/trash') == 1 then
        return { '/usr/bin/trash', path }
    elseif platform ~= 'windows' and vim.fn.executable('gio') == 1 then
        return { 'gio', 'trash', '--', path }
    end
end

function file_commands.delete_file()
    local buffer = api.nvim_get_current_buf()
    local path = api.nvim_buf_get_name(buffer)
    if path == '' then
        return
    end
    local trash_command, trash_environment = command_to_move_to_trash(path)
    local question = trash_command and ('Move ' .. path .. ' to the Recycle Bin?') or ('There is no Recycle Bin for ' .. path .. '. Delete it permanently?')
    if vim.bo[buffer].modified then
        question = question .. '\nIts unsaved changes will be lost.'
    end
    if vim.fn.confirm(question, '&Yes\n&No', 2, 'Warning') ~= 1 then
        return
    end
    local removed
    if trash_command then
        local environment = helpers.windows_child_environment(trash_environment)
        local ok, result = pcall(function()
            return vim.system(trash_command, { text = true, env = environment, cwd = helpers.platform() == 'wsl' and '/' or nil }):wait(30000)
        end)
        removed = ok and result.code == 0 and vim.fn.filereadable(path) == 0
    else
        removed = vim.fn.delete(path) == 0
    end
    if removed then
        file_commands.close(buffer, { force = true })
    else
        helpers.warn('Could not remove ' .. path)
    end
end

return file_commands
