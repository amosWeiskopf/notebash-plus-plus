-- language servers without setup: open a document in a known language and, if
-- its usual server program is on the path, start it with neovim's
-- vim.lsp.config and vim.lsp.enable. nothing gets installed, downloaded or
-- asked. i want an editor, not another bastard with purchasing authority.
-- user.lua disables all with language_servers = false, or selected servers
-- with language_servers_off = { 'clangd' }.
--
-- presentation follows notepad++ plugins: underline problems & mark them in
-- the margin. resting the caret on one opens details in a small window. no
-- virtual text after the line. my failures need absolutely no subtitles.

local language_servers = {}
local api = vim.api
local helpers = require('notebashpp.helpers')

-- known servers: name is the vim.lsp.config name; look up program on the
-- path, then append arguments. root_markers locate the project folder.
-- preferred_alternative: skip this server if that one is on the path too.
-- runs_project_code: the server can run code the project ships (build
-- scripts, proc macros, a project's own typescript or python, build.zig), so
-- it waits until you trust the folder.
-- basically a succession plan for processes. mine is less organized.
language_servers.definitions = {
    {
        name = 'lua_ls',
        runs_project_code = true,
        program = 'lua-language-server',
        arguments = {},
        filetypes = { 'lua' },
        root_markers = { '.luarc.json', '.luarc.jsonc', '.stylua.toml', 'stylua.toml', 'selene.toml', '.git' },
    },
    {
        name = 'basedpyright',
        runs_project_code = true,
        program = 'basedpyright-langserver',
        arguments = { '--stdio' },
        filetypes = { 'python' },
        root_markers = { 'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', 'Pipfile', 'pyrightconfig.json', '.git' },
    },
    {
        name = 'pyright',
        runs_project_code = true,
        program = 'pyright-langserver',
        arguments = { '--stdio' },
        filetypes = { 'python' },
        root_markers = { 'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', 'Pipfile', 'pyrightconfig.json', '.git' },
        preferred_alternative = 'basedpyright',
    },
    {
        name = 'ts_ls',
        runs_project_code = true,
        program = 'typescript-language-server',
        arguments = { '--stdio' },
        filetypes = { 'javascript', 'javascriptreact', 'typescript', 'typescriptreact' },
        root_markers = { 'tsconfig.json', 'jsconfig.json', 'package.json', '.git' },
    },
    {
        name = 'clangd',
        program = 'clangd',
        arguments = {},
        filetypes = { 'c', 'cpp', 'objc', 'objcpp', 'cuda' },
        root_markers = { 'compile_commands.json', 'compile_flags.txt', '.clangd', '.git' },
    },
    {
        name = 'rust_analyzer',
        runs_project_code = true,
        program = 'rust-analyzer',
        arguments = {},
        filetypes = { 'rust' },
        root_markers = { 'Cargo.toml', 'rust-project.json', '.git' },
    },
    {
        name = 'gopls',
        runs_project_code = true,
        program = 'gopls',
        arguments = {},
        filetypes = { 'go', 'gomod', 'gowork', 'gotmpl' },
        root_markers = { 'go.work', 'go.mod', '.git' },
    },
    {
        name = 'bashls',
        program = 'bash-language-server',
        arguments = { 'start' },
        filetypes = { 'sh', 'bash' },
        root_markers = { '.git' },
    },
    {
        name = 'jsonls',
        program = 'vscode-json-language-server',
        arguments = { '--stdio' },
        filetypes = { 'json', 'jsonc' },
        root_markers = { 'package.json', '.git' },
        init_options = { provideFormatter = true },
    },
    {
        name = 'html',
        program = 'vscode-html-language-server',
        arguments = { '--stdio' },
        filetypes = { 'html' },
        root_markers = { 'package.json', '.git' },
        init_options = { provideFormatter = true },
    },
    {
        name = 'cssls',
        program = 'vscode-css-language-server',
        arguments = { '--stdio' },
        filetypes = { 'css', 'scss', 'less' },
        root_markers = { 'package.json', '.git' },
        init_options = { provideFormatter = true },
    },
    {
        name = 'yamlls',
        program = 'yaml-language-server',
        arguments = { '--stdio' },
        filetypes = { 'yaml' },
        root_markers = { '.git' },
    },
    {
        name = 'marksman',
        program = 'marksman',
        arguments = { 'server' },
        filetypes = { 'markdown' },
        root_markers = { '.marksman.toml', '.git' },
    },
    {
        name = 'taplo',
        program = 'taplo',
        arguments = { 'lsp', 'stdio' },
        filetypes = { 'toml' },
        root_markers = { '.taplo.toml', 'taplo.toml', '.git' },
    },
    {
        name = 'zls',
        runs_project_code = true,
        program = 'zls',
        arguments = {},
        filetypes = { 'zig' },
        root_markers = { 'build.zig', 'zls.json', '.git' },
    },
}

local definition_by_name = {}
for _, definition in ipairs(language_servers.definitions) do
    definition_by_name[definition.name] = definition
end

-- server name to full program path, or false if absent from the path. look up
-- each program once; look_again() forgets. cheaper than drinking.
local program_paths = {}
-- names handed to vim.lsp.enable this session. shit we already committed to.
local enabled_names = {}
local presentation_ready = false

local function settings()
    return require('notebashpp.user_settings')
end

local function switched_on()
    return settings().get('language_servers') ~= false
end

-- the off list accepts server names (clangd, lua_ls) or program names
-- (lua-language-server). i want quitting to be easy somewhere.
local function switched_off(definition)
    for _, off_name in ipairs(settings().get('language_servers_off') or {}) do
        if off_name == definition.name or off_name == definition.program then
            return true
        end
    end
    return false
end

local function program_path(definition)
    if program_paths[definition.name] == nil then
        local found = vim.fn.exepath(definition.program)
        program_paths[definition.name] = found ~= '' and found or false
    end
    return program_paths[definition.name]
end

-- usable means its program is on the path, it is not switched off, and no
-- preferred alternative is usable instead. even software can be replaced. i
-- try not to dwell on that.
local function usable(definition)
    if switched_off(definition) or not program_path(definition) then
        return false
    end
    local alternative = definition.preferred_alternative and definition_by_name[definition.preferred_alternative]
    if alternative and not switched_off(alternative) and program_path(alternative) then
        return false
    end
    return true
end

-- project folder: nearest folder up from the file containing a marker, but
-- never home, the filesystem root or anything above home: a stray
-- package.json in ~ would make a server index the whole damn disk to judge
-- one typo. the search stops below home. no marker means no project folder
-- and the server sees just the file. documents never saved get no server.
-- apparently you need a permanent address to be criticized.
local function is_too_wide(folder)
    local home_folder = vim.fs.normalize(vim.uv.os_homedir() or '')
    folder = vim.fs.normalize(folder)
    if folder == '/' or folder:match('^%a:/?$') or folder == home_folder then
        return true
    end
    return home_folder:sub(1, #folder + 1) == folder .. '/'
end

local function project_folder(file_name, root_markers)
    local found = vim.fs.find(root_markers, {
        path = vim.fs.dirname(file_name),
        upward = true,
        stop = vim.uv.os_homedir(),
        limit = 1,
    })[1]
    local folder = found and vim.fs.dirname(found)
    if folder and not is_too_wide(folder) then
        return folder
    end
    return nil
end

-- folders you said may run their own code. kept in preferences.json. a
-- folder counts as trusted when it or a folder above it is on the list.
-- it's more trust than anyone ever extended to me.
local function trusted_folders()
    local folders = require('notebashpp.preferences').get('trusted_language_server_folders', {})
    return type(folders) == 'table' and folders or {}
end

local function is_trusted(folder)
    folder = vim.fs.normalize(folder)
    for _, trusted_folder in ipairs(trusted_folders()) do
        if type(trusted_folder) == 'string' and (folder == trusted_folder or folder:sub(1, #trusted_folder + 1) == trusted_folder .. '/') then
            return true
        end
    end
    return false
end

-- the folder a server would run code from: the project folder, else the
-- file's own folder.
local function trust_folder_for(definition, file_name)
    return project_folder(file_name, definition.root_markers) or vim.fs.dirname(file_name)
end

-- servers held back per folder, so the notice shows once, not on every
-- document. i also only need to be told no once. i get told repeatedly.
local held_back_notices = {}

local function root_folder_finder(definition)
    return function(buffer, on_root_folder)
        local file_name = api.nvim_buf_get_name(buffer)
        if file_name == '' then
            return
        end
        if definition.runs_project_code then
            local folder = trust_folder_for(definition, file_name)
            if not is_trusted(folder) then
                local notice_key = definition.name .. '\n' .. folder
                if not held_back_notices[notice_key] then
                    held_back_notices[notice_key] = true
                    helpers.notify(
                        ('%s was not started: it can run code from %s. If you trust that folder, use Plugins, Language Server, Trust This Folder.'):format(
                            definition.program,
                            folder
                        )
                    )
                end
                return
            end
        end
        on_root_folder(project_folder(file_name, definition.root_markers))
    end
end

-- notepad++ underlines problems & marks the margin: no virtual text, details
-- in a float. we stay in insert mode, so update diagnostics there too.
-- discard server output & lsp log lines instead of letting lsp.log grow
-- without limit. my mistakes already occupy enough fucking space.
local function prepare_presentation()
    if presentation_ready then
        return
    end
    presentation_ready = true
    vim.lsp.log.set_level(vim.log.levels.OFF)
    vim.diagnostic.config({
        underline = true,
        virtual_text = false,
        virtual_lines = false,
        signs = { priority = 10 },
        update_in_insert = true,
        severity_sort = true,
        float = { border = 'single', source = 'if_many', header = '', focusable = false },
    })
end

local function enable_server(definition)
    prepare_presentation()
    vim.fn.mkdir(vim.fn.stdpath('state'), 'p')
    ---@type string[]
    local command = { program_path(definition) }
    for _, argument in ipairs(definition.arguments) do
        command[#command + 1] = argument
    end
    vim.lsp.config(definition.name, {
        cmd = command,
        filetypes = definition.filetypes,
        root_dir = root_folder_finder(definition),
        -- servers start in neovim's state folder, not wherever you launched
        -- the editor. rustup reads rust-toolchain.toml from the current folder
        -- and will happily run a binary a repo ships. i run enough bad
        -- decisions from the wrong directory.
        cmd_cwd = vim.fn.stdpath('state'),
        init_options = definition.init_options,
        -- notepad++ colours by lexer only. server semantic colouring would
        -- repaint the document in other colours. even my text gets an
        -- unwanted makeover.
        on_init = function(client)
            client.server_capabilities.semanticTokensProvider = nil
        end,
    })
    enabled_names[definition.name] = true
    vim.lsp.enable(definition.name)
end

-- enable every usable server for this buffer's filetype. vim.lsp.enable
-- starts it here & in every later buffer of that type. criticism on a
-- subscription, basically.
function language_servers.enable_for_buffer(buffer)
    if not switched_on() or not api.nvim_buf_is_valid(buffer) or vim.bo[buffer].buftype ~= '' then
        return
    end
    local filetype = vim.bo[buffer].filetype
    if filetype == '' then
        return
    end
    for _, definition in ipairs(language_servers.definitions) do
        if not enabled_names[definition.name] and vim.tbl_contains(definition.filetypes, filetype) and usable(definition) then
            enable_server(definition)
        end
    end
end

-- forget found programs, stop servers now missing or switched off, then check
-- every open document again. use after installing a server or editing
-- user.lua. i keep giving software another chance. look where that got me.
function language_servers.look_again()
    program_paths = {}
    for name in pairs(enabled_names) do
        if not switched_on() or not usable(definition_by_name[name]) then
            vim.lsp.enable(name, false)
            for _, client in ipairs(vim.lsp.get_clients({ name = name })) do
                client:stop()
            end
            enabled_names[name] = nil
        end
    end
    for _, buffer in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buffer) then
            language_servers.enable_for_buffer(buffer)
        end
    end
end

-- the folder the current document's code-running servers would use, or nil
-- when none of its servers runs project code.
local function folder_to_trust(buffer)
    local file_name = api.nvim_buf_get_name(buffer)
    if file_name == '' then
        return nil
    end
    local filetype = vim.bo[buffer].filetype
    for _, definition in ipairs(language_servers.definitions) do
        if definition.runs_project_code and vim.tbl_contains(definition.filetypes, filetype) and usable(definition) then
            return trust_folder_for(definition, file_name)
        end
    end
    return nil
end

-- plugins, language server, trust this folder: ask once, remember the
-- folder, then start the waiting servers in every open document inside it.
-- trust given on purpose, with a dialog. that's how it should have gone
-- every other time too.
function language_servers.trust_folder(buffer)
    buffer = buffer or api.nvim_get_current_buf()
    local folder = folder_to_trust(buffer)
    if not folder then
        return helpers.warn('No language server for this document runs code from its folder.')
    end
    if is_trusted(folder) then
        return helpers.notify(folder .. ' is already trusted.')
    end
    local answer = vim.fn.confirm(
        ('Let language servers run code from this folder?\n\n%s\n\nBuild scripts, macros and tools inside it can run with your permissions. Trust it only if you trust where it came from.'):format(
            folder
        ),
        '&Trust\n&Cancel',
        2
    )
    if answer ~= 1 then
        return
    end
    local folders = vim.deepcopy(trusted_folders())
    folders[#folders + 1] = vim.fs.normalize(folder)
    require('notebashpp.preferences').set('trusted_language_server_folders', folders)
    for _, other_buffer in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(other_buffer) and vim.bo[other_buffer].buftype == '' and vim.bo[other_buffer].filetype ~= '' then
            pcall(api.nvim_exec_autocmds, 'FileType', { group = 'nvim.lsp.enable', buffer = other_buffer })
        end
    end
end

-- forget every trusted folder and stop the servers that ran on that trust.
-- burning the bridges myself, for once.
function language_servers.forget_trusted_folders()
    require('notebashpp.preferences').set('trusted_language_server_folders', {})
    held_back_notices = {}
    for name in pairs(enabled_names) do
        if definition_by_name[name].runs_project_code then
            for _, client in ipairs(vim.lsp.get_clients({ name = name })) do
                client:stop()
            end
        end
    end
    helpers.notify('No folder is trusted any more; code-running language servers stopped.')
end

------------------------------------------------------------- status

local function clients_of(buffer)
    return vim.lsp.get_clients({ bufnr = buffer or api.nvim_get_current_buf() })
end

-- one menu line: servers running for this document, or why nobody showed up.
function language_servers.status_line(buffer)
    buffer = buffer or api.nvim_get_current_buf()
    if not switched_on() then
        return 'Language servers are off (user.lua)'
    end
    local names = {}
    for _, client in ipairs(clients_of(buffer)) do
        names[#names + 1] = client.name
    end
    if #names > 0 then
        return 'Running: ' .. table.concat(names, ', ')
    end
    local filetype = vim.bo[buffer].filetype
    local missing_programs, off_names = {}, {}
    for _, definition in ipairs(language_servers.definitions) do
        if vim.tbl_contains(definition.filetypes, filetype) then
            if usable(definition) then
                if api.nvim_buf_get_name(buffer) == '' then
                    return definition.name .. ' starts once the document is saved'
                end
                if definition.runs_project_code and not is_trusted(trust_folder_for(definition, api.nvim_buf_get_name(buffer))) then
                    return definition.name .. ' waits until you trust this folder'
                end
                return definition.name .. ' is starting'
            elseif switched_off(definition) then
                off_names[#off_names + 1] = definition.name
            elseif not program_path(definition) then
                missing_programs[#missing_programs + 1] = definition.program
            end
        end
    end
    if #off_names > 0 then
        return 'Off in user.lua: ' .. table.concat(off_names, ', ')
    end
    if #missing_programs > 0 then
        return 'Not on the path: ' .. table.concat(missing_programs, ', ')
    end
    return 'No language server for this document'
end

-- longer status: each running server, its program & folder. a shit census.
function language_servers.show_status(buffer)
    buffer = buffer or api.nvim_get_current_buf()
    local lines = { language_servers.status_line(buffer) }
    for _, client in ipairs(clients_of(buffer)) do
        local command = client.config.cmd
        local command_text = type(command) == 'table' and table.concat(command, ' ') or '(function)'
        lines[#lines + 1] = ('%s: %s, folder %s'):format(client.name, command_text, client.root_dir or '(none)')
    end
    helpers.notify(table.concat(lines, '\n'))
end

------------------------------------------------------------- commands

-- true if an attached server can answer `method`; otherwise say so & return
-- false. i'd love to admit my own limits this cheaply.
local function server_can(method, what)
    for _, client in ipairs(clients_of()) do
        if client:supports_method(method) then
            return true
        end
    end
    helpers.warn(('No language server for this document can %s.'):format(what))
    return false
end

-- jump to a quickfix-style item: switch document if needed, place the caret
-- (col is 1-based) & drop any selection. abandon something small for once.
local function go_to_item(item)
    local target_file = item.filename or api.nvim_buf_get_name(item.bufnr)
    if vim.fs.normalize(target_file) ~= vim.fs.normalize(api.nvim_buf_get_name(0)) then
        helpers.collapse_selection()
        require('notebashpp.file_commands').open_path(target_file)
    end
    helpers.move_caret_to({ item.lnum, math.max(0, (item.col or 1) - 1) })
end

-- one definition: go there. several: results panel. shit, even truth forks.
function language_servers.go_to_definition()
    if not server_can('textDocument/definition', 'go to a definition') then
        return
    end
    local word = helpers.word_at_caret()
    vim.lsp.buf.definition({
        on_list = function(list)
            if #list.items == 1 then
                go_to_item(list.items[1])
            else
                language_servers.show_in_results(list.items, ('Definitions of "%s"'):format(word))
            end
        end,
    })
end

-- references use the results panel, like find in files: f4 & shift+f4 step
-- through them, enter opens one. a guided tour of everywhere i fucked up.
function language_servers.find_references()
    if not server_can('textDocument/references', 'find references') then
        return
    end
    local word = helpers.word_at_caret()
    vim.lsp.buf.references({ includeDeclaration = true }, {
        on_list = function(list)
            language_servers.show_in_results(list.items, ('References to "%s"'):format(word))
        end,
    })
end

function language_servers.show_in_results(items, title)
    local file_names = {}
    for _, item in ipairs(items) do
        file_names[item.filename or item.bufnr] = true
    end
    local file_count = vim.tbl_count(file_names)
    local full_title = ('%s (%d hit%s in %d file%s)'):format(title, #items, #items == 1 and '' or 's', file_count, file_count == 1 and '' or 's')
    require('notebashpp.find_and_replace').show_results(items, full_title)
end

-- ask for a new name, with the current name filled in. the server changes
-- every file it knows about; ctrl+z undoes it per document. regret remains a
-- manual process. of course it does.
function language_servers.rename_symbol()
    if not server_can('textDocument/rename', 'rename') then
        return
    end
    local old_name = helpers.word_at_caret()
    local new_name = helpers.ask('Rename to: ', old_name)
    if new_name == '' or new_name == old_name then
        return
    end
    vim.lsp.buf.rename(new_name)
end

-- documentation floats without taking the caret; moving or typing closes it.
-- advice i can actually make disappear.
function language_servers.hover()
    if not server_can('textDocument/hover', 'show documentation') then
        return
    end
    vim.lsp.buf.hover({ border = 'single', focusable = false, focus = false })
end

function language_servers.format_document()
    if not server_can('textDocument/formatting', 'format') then
        return
    end
    helpers.collapse_selection()
    vim.lsp.buf.format({ async = true, bufnr = api.nvim_get_current_buf() })
end

------------------------------------------------------------- diagnostics

-- open details float & the caret position under interrogation
local details_window, details_position = nil, nil

local function close_details()
    if details_window and api.nvim_win_is_valid(details_window) then
        pcall(api.nvim_win_close, details_window, true)
    end
    details_window, details_position = nil, nil
end

-- show problems at `position` ({line, col}, col 0-based) in a float without
-- taking focus. return true if there was something to show. the machine found
-- fault with me; thank god we recorded its success.
function language_servers.show_details(position)
    if not presentation_ready then
        return false
    end
    position = position or helpers.get_caret()
    close_details()
    local _, window = vim.diagnostic.open_float({
        bufnr = api.nvim_get_current_buf(),
        scope = 'cursor',
        pos = { position[1] - 1, position[2] },
        focusable = false,
        close_events = { 'InsertCharPre', 'BufLeave', 'BufHidden' },
    })
    if window then
        details_window, details_position = window, { position[1], position[2] }
    end
    return window ~= nil
end

-- details key: show the problem under the caret, else the nearest on its
-- line. apparently i can't even miss a problem properly.
function language_servers.diagnostic_details()
    local caret = helpers.get_caret()
    if language_servers.show_details(caret) then
        return
    end
    local on_line = vim.diagnostic.get(0, { lnum = caret[1] - 1 })
    if on_line[1] then
        language_servers.show_details({ caret[1], on_line[1].col })
    else
        helpers.notify('No problem reported at the caret.')
    end
end

-- next or previous problem, wrapping around. move the caret to its start &
-- open details. basically regret with a working transport system.
function language_servers.jump_to_diagnostic(direction)
    local diagnostic
    if direction > 0 then
        diagnostic = vim.diagnostic.get_next({ wrap = true })
    else
        diagnostic = vim.diagnostic.get_prev({ wrap = true })
    end
    if not diagnostic then
        helpers.notify('No problems reported in this document.')
        return
    end
    local target = { diagnostic.lnum + 1, diagnostic.col }
    helpers.move_caret_to(target)
    -- move_caret_to may finish via queued keys; float after. damn queue.
    vim.schedule(function()
        language_servers.show_details(target)
    end)
end

-- rest the caret on a problem for details; moving closes them. flee cheaply.
local function on_caret_rest()
    if not presentation_ready or vim.fn.pumvisible() == 1 or not helpers.is_editable_buffer() then
        return
    end
    if details_window and api.nvim_win_is_valid(details_window) then
        return
    end
    if next(vim.diagnostic.get(0)) then
        language_servers.show_details(helpers.get_caret())
    end
end

local function on_caret_moved()
    if not details_position then
        return
    end
    local caret = helpers.get_caret()
    if caret[1] ~= details_position[1] or caret[2] ~= details_position[2] then
        close_details()
    end
end

function language_servers.setup()
    local autocommand_group = api.nvim_create_augroup('notebashpp_language_servers', { clear = true })
    -- schedule so the document appears before searching the path, and so
    -- vim.lsp.enable sees startup finished & starts the first document. even
    -- this shit needs a moment to face the day.
    api.nvim_create_autocmd('FileType', {
        group = autocommand_group,
        callback = function(event)
            vim.schedule(function()
                language_servers.enable_for_buffer(event.buf)
            end)
        end,
    })
    -- function completion (ctrl+space) uses 'omnifunc'. neovim sets it to the
    -- server only if no filetype plugin set its own, so set it here. i want
    -- completion. apparently i also need a fucking custody hearing.
    api.nvim_create_autocmd('LspAttach', {
        group = autocommand_group,
        callback = function(event)
            local client = vim.lsp.get_client_by_id(event.data.client_id)
            if client and client:supports_method('textDocument/completion') then
                vim.bo[event.buf].omnifunc = 'v:lua.vim.lsp.omnifunc'
            end
        end,
    })
    api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, { group = autocommand_group, callback = on_caret_rest })
    api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, { group = autocommand_group, callback = on_caret_moved })
    -- handle already-open documents after live code reload. still here, damn
    -- it.
    if vim.v.vim_did_enter == 1 then
        vim.schedule(language_servers.look_again)
    end
end

function language_servers._unload()
    close_details()
end

return language_servers
